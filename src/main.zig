//! Entry point + wiring. main() resolves the install paths, brings up Auth + the Supervisor, and starts the HTTP
//! server — or dispatches a CLI verb / the worker entry when invoked as a subcommand.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");

const NEURON_EXE = if (builtin.os.tag == .windows) "neuron.exe" else "neuron";
const Neuron = @import("worker/neuron/client.zig").Neuron;
const Auth = @import("auth/auth_core.zig").Auth;
const Supervisor = @import("worker/control/supervisor.zig").Supervisor;
const crypto = @import("config/key_vault.zig");
const KeyVault = crypto.KeyVault;
const AuditLog = @import("obs/audit_log.zig").AuditLog;
const LoginGuard = @import("auth/login_guard.zig").LoginGuard;
const http = @import("gateway/http.zig");
const App = http.App;

const auth_api = @import("auth/auth_api.zig");
const deploy_service = @import("worker/deploy/service.zig");
const tail_fanout = @import("worker/control/fanout.zig");
const control_writer = @import("worker/control/writer.zig");
const chat_tools = @import("worker/chat/tools.zig");
const chat_service = @import("worker/chat/service.zig");
const sched = @import("worker/sched.zig");
const metrics = @import("worker/metrics.zig");
const rate = @import("worker/rate.zig");
const admin_service = @import("admin/admin_service.zig");
const billing_seam = @import("plan/billing_seam.zig");
const keys_api = @import("config/keys_api.zig");
const cf_oauth = @import("config/cf_oauth.zig");
const worker = @import("worker/run.zig");
const cli = @import("cli.zig");

// .info, explicitly: the default log_level tracks the optimize mode, and the ReleaseFast default (.err)
// would silently swallow every operational message below — including the one-shot generated-admin-password
// banner. This is the single binary-wide switch; per-module scopes are declared at each file's top.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false, .log_level = .info };

const log = std.log.scoped(.server);

const VERSION = "1.0.0";

const ASSET_HTML = @embedFile("index.html");
const ASSET_JS = @embedFile("app.js");
const ASSET_CSS = @embedFile("styles.css");
const ASSET_MODELS = @embedFile("models.json");

const Paths = struct { home: []const u8, data: []const u8, neuron_bin: []const u8 };

fn resolvePaths(gpa: std.mem.Allocator, io: std.Io) !Paths {
    var buf: [4096]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    const exe_dir = std.fs.path.dirname(buf[0..n]) orelse ".";
    var home: []const u8 = exe_dir;
    if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) {
        if (std.fs.path.dirname(exe_dir)) |p1| {
            if (std.mem.eql(u8, std.fs.path.basename(p1), "zig-out"))
                home = std.fs.path.dirname(p1) orelse exe_dir;
        }
    }
    home = try gpa.dupe(u8, home);
    return .{
        .home = home,
        .data = try std.fmt.allocPrint(gpa, "{s}/data", .{home}),
        .neuron_bin = try std.fmt.allocPrint(gpa, "{s}/bin/{s}", .{ home, NEURON_EXE }),
    };
}

fn runQuiet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const r = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(4 << 10) }) catch return;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

/// AUTO-CONFIGURE local Ollama for effective agentic use. Two env vars decide whether local casts crawl:
/// OLLAMA_NUM_PARALLEL (unset=1 → the cast's minds + the chat all serialize through ONE runner) and
/// OLLAMA_CONTEXT_LENGTH (unset → gpt-oss loads its full 131072 window, spilling the KV cache to CPU at
/// ~1 tok/s). Ollama reads BOTH only at serve-start, so we persist sane defaults with `setx` and restart the
/// Ollama server (its tray app relaunches it with the fresh env). Runs only when a local Ollama is actually
/// reachable, only touches vars that are unset/too-low, and no-ops thereafter. Opt out: NL_NO_OLLAMA_TUNE=1.
fn tuneOllama(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    if (builtin.os.tag != .windows) return; // setx/taskkill path is Windows-specific for now
    if (environ.get("NL_NO_OLLAMA_TUNE")) |v| if (v.len > 0) return;
    // only act if a local Ollama is actually up (in-process probe — no curl child at startup)
    {
        const httpc = @import("worker/httpc.zig");
        switch (httpc.request(io, gpa, .{ .method = "GET", .port = 11434, .path = "/api/version", .timeout_s = 3, .cap = 4 << 10 })) {
            .ok => |resp| {
                const up = resp.status == 200 and resp.body.len >= 2;
                if (resp.body.len > 0) gpa.free(resp.body);
                if (!up) return;
            },
            else => return,
        }
    }
    const cur_par = std.mem.trim(u8, environ.get("OLLAMA_NUM_PARALLEL") orelse "", " \r\n\t");
    const cur_ctx = std.mem.trim(u8, environ.get("OLLAMA_CONTEXT_LENGTH") orelse "", " \r\n\t");
    const par_ok = (std.fmt.parseInt(u32, cur_par, 10) catch 0) >= 2;
    const ctx_ok = cur_ctx.len > 0; // any explicit context = the user's choice, leave it
    if (par_ok and ctx_ok) return; // already tuned — nothing to do
    // Persist sane defaults for the NEXT Ollama start. We deliberately DO NOT kill a running Ollama here — a
    // bare `ollama serve` has no tray to relaunch it, so killing it would leave the machine with no model. The
    // vars apply on Ollama's next start (reboot / tray restart / manual `ollama serve`); print the one-liner so
    // the user can apply them now if they want the speedup this session.
    // 2, not 4: on a single box a 20b model at 4 parallel slots (3 cast minds + a chat turn) saturates the
    // CPU/RAM until the HTTP server starves. 2 keeps some concurrency for steering without oversubscribing.
    if (!par_ok) runQuiet(gpa, io, &.{ "setx", "OLLAMA_NUM_PARALLEL", "2" });
    if (!ctx_ok) runQuiet(gpa, io, &.{ "setx", "OLLAMA_CONTEXT_LENGTH", "8192" });
    log.info("persisted Ollama tuning (OLLAMA_NUM_PARALLEL=2, OLLAMA_CONTEXT_LENGTH=8192). Restart Ollama to apply now — casts will run parallel + fast instead of serializing on the CPU.", .{});
}

/// `--server-only` (alias `--headless`): opt OUT of the one-click default and boot the server alone — no desk.
/// For headless hosts, service managers, and internal auto-starts that bring up their own UI.
fn isServerOnly(a: []const u8) bool {
    return std.mem.eql(u8, a, "--server-only") or std.mem.eql(u8, a, "--headless");
}

// Win32 bits for the two app-mode lifecycle behaviours below (console detach + own-the-tree shutdown). Direct
// externs, matching how supervisor.zig / run.zig already reach for kernel32 — no subprocess, no shell.
const winapp = if (builtin.os.tag == .windows) struct {
    const HANDLE = *anyopaque;
    const BOOL = c_int; // Win32 BOOL is a 32-bit int at the ABI; plain c_int lets `0` coerce cleanly
    const INFINITE: u32 = 0xFFFF_FFFF;
    /// Number of processes attached to OUR console. 1 = we are the only one (double-click / Explorer gave us a
    /// fresh console); >=2 = a shell (cmd.exe, powershell.exe) is attached and that console is the DEV'S, not
    /// ours. 0 = the call failed / no console at all.
    extern "kernel32" fn GetConsoleProcessList(list: [*]u32, count: u32) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    // --- Job object: one kill-on-close job holding this process, so every descendant (desk, workers, neuron,
    // browser) dies with us even when we are hard-killed and never run a defer.
    const JobObjectExtendedLimitInformation: c_int = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: u32,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: u32,
        Affinity: usize,
        PriorityClass: u32,
        SchedulingClass: u32,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    extern "kernel32" fn CreateJobObjectW(sec: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *anyopaque, len: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, proc: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
} else struct {};

/// Sleep `ms` from a RAW OS thread (the desk watcher is a std.Thread, NOT an Io-managed task — io.sleep throws
/// there). Same shape as supervisor.zig's threadSleepMs, for the same reason.
fn threadSleepMs(io: std.Io, ms: u64) void {
    if (builtin.os.tag == .windows) {
        winapp.Sleep(@intCast(ms));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

/// Set on the relaunched copy so the detach below can never recurse.
///
/// DO NOT REMOVE THIS AS "REDUNDANT" — it is the ONLY thing standing between a double-click and a fork bomb.
/// CREATE_NO_WINDOW does NOT mean "no console": Windows still gives the child its own console, just an
/// invisible one, and the child is the sole process on it. MEASURED: a process spawned with create_no_window
/// reports GetConsoleProcessList() == 1, exactly like a double-click. So the count guard alone would make
/// every relaunch relaunch again, forever. This marker is what actually terminates the recursion.
const CONSOLE_DETACH_MARKER = "NL_CONSOLE_DETACHED";

/// THE DOUBLE-CLICK CONSOLE. `veil` is — and must stay — a CONSOLE-subsystem binary: flipping it to
/// `.subsystem = .Windows` makes cmd.exe and PowerShell stop waiting for it and throws away its stdout even
/// when redirected, which would gut every CLI verb. FreeConsole()/ShowWindow(SW_HIDE) is equally wrong: run
/// from a shell, those hide the DEVELOPER'S OWN terminal.
///
/// So: relaunch ourselves detached with CREATE_NO_WINDOW and exit the parent — but ONLY when we are the sole
/// process attached to this console (GetConsoleProcessList() == 1), which is exactly the Explorer/double-click
/// case. Started from a shell, cmd.exe/powershell.exe is attached too, the count is >= 2, and we do nothing:
/// the dev keeps their terminal and their output.
///
/// Returns true when the relaunch was spawned and the caller must exit immediately. Opt out: NL_NO_CONSOLE_DETACH=1.
fn detachOwnConsole(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, sub: []const u8, rest: []const []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    // FIRST, and load-bearing: the relaunched copy also sees a console count of 1 (see CONSOLE_DETACH_MARKER).
    if (environ.get(CONSOLE_DETACH_MARKER)) |v| if (v.len > 0) return false; // already the relaunched copy
    if (environ.get("NL_NO_CONSOLE_DETACH")) |v| if (v.len > 0 and !std.mem.eql(u8, v, "0")) return false;
    // THE GUARD. Anything other than "exactly us" means a shell owns this console — leave it alone.
    var pids: [8]u32 = undefined;
    if (winapp.GetConsoleProcessList(&pids, pids.len) != 1) return false;

    var exe_buf: [4096]u8 = undefined;
    const exe_n = std.process.executablePath(io, &exe_buf) catch return false;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, exe_buf[0..exe_n]) catch return false;
    if (sub.len > 0) argv.append(gpa, sub) catch return false; // same args, verbatim
    for (rest) |a| argv.append(gpa, a) catch return false;

    var env2 = environ.clone(gpa) catch return false;
    defer env2.deinit();
    env2.put(CONSOLE_DETACH_MARKER, "1") catch return false;
    _ = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
        .environ_map = &env2,
    }) catch return false;
    return true;
}

/// APP MODE ONLY. Put THIS process in a kill-on-job-close job so every process we spawn from here on (the
/// desk, swarm workers, neuron, the browser host) is a job member too. When we die — cleanly OR via Task
/// Manager / a hard kill, where no defer and no watcher ever runs — our handle is the job's last, the job
/// closes, and Windows terminates the whole remaining tree. That is the only orphan-proof mechanism here;
/// watchDesk below handles the ordinary "user closed the desk" case. Best-effort: on failure we simply keep
/// the old behaviour. Never called for --server-only (a service manager owns that tree, not us).
///
/// KNOWN TRADEOFF — read before widening this. The `local-host` browser daemon (worker/browser/host.zig) is
/// deliberately built to OUTLIVE a server restart: it runs from a TEMP copy of the exe specifically so restart
/// scripts don't have to kill it, keeping a warm browser instead of "a cold Edge for the next call, every
/// time". It is spawned from tool execution, which descends from us, so in app mode it now joins this job and
/// dies with us — re-introducing the cold start that trick existed to avoid. It is a warm-cache regression,
/// not a correctness one (ensure() just respawns a daemon on demand), and it cannot be fixed from this file:
/// the daemon would need CREATE_BREAKAWAY_FROM_JOB, which std.process.spawn does not expose today. Hence the
/// escape hatch below — NL_NO_JOB_OBJECT=1 restores the old orphan-prone-but-warm behaviour without a rebuild.
fn ownProcessTree(environ: *std.process.Environ.Map) void {
    if (builtin.os.tag != .windows) return;
    if (environ.get("NL_NO_JOB_OBJECT")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return;
    }
    // Deliberately NOT closed: the handle must live for the whole process, and its release at exit is the
    // signal that kills the tree. Non-inheritable by default (null security attrs), so no child can keep the
    // job alive by holding a copy.
    const job = winapp.CreateJobObjectW(null, null) orelse return;
    var info: winapp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(winapp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    info.BasicLimitInformation.LimitFlags = winapp.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (winapp.SetInformationJobObject(job, winapp.JobObjectExtendedLimitInformation, @ptrCast(&info), @sizeOf(winapp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) return;
    // Nested jobs are fine on Win8+; if we are already in a job that refuses nesting this just fails and we
    // fall back to the watcher path.
    if (winapp.AssignProcessToJobObject(job, winapp.GetCurrentProcess()) == 0) return;
    log.info("process tree: this server + everything it spawns now live in one kill-on-close job (app mode)", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // ONE-CLICK DEFAULT: a bare `veil` — what a double-click runs — boots the server AND opens the desk, so the
    // shipped bundle is a single icon that brings the whole app up. `--server-only` (alias `--headless`) keeps
    // the server-only behaviour for headless boxes, service managers, and every internal auto-start that
    // launches its own UI (cli.zig ensureServer and restart-veil.ps1 both pass it). CLI verbs are unaffected:
    // they run and return well before the server (and therefore the desk) is ever started.
    var desktop_mode = true;
    // A real threaded io instead of the default init.io. httpz runs a pool of ~32 worker threads that
    // correctly BLOCK on a condition variable when there is no work — but the default init.io busy-SPINS
    // those blocking waits on Windows, pinning ~10 CPU cores with the server completely idle (0 swarms, no
    // requests) and cooking the machine. std.Io.Threaded (exactly what the desktop already uses, and which
    // sits at ~0% idle) sleeps its waits on OS primitives. MUST carry the process environ or Winsock +
    // subprocess spawns break on Windows (the empty-environ gotcha) — the server spawns workers/neuron/curl.
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Collect the subcommand + its remaining argv up front. `worker` short-circuits to the worker entry (that
    // is how the supervisor spawns a mind); a recognized CLI verb (cli.isCommand) runs the command-line client
    // and returns; `--desk` arms desktop hosting; anything else falls through to booting the server daemon.
    var cli_sub: []const u8 = "";
    var cli_args: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.process.Args.Iterator.initAllocator(init.minimal.args, gpa)) |it_const| {
        var it = it_const;
        defer it.deinit();
        _ = it.skip();
        if (it.next()) |sub| {
            if (std.mem.eql(u8, sub, "worker")) {
                const run_dir = try gpa.dupe(u8, it.next() orelse "");
                const nbin = try gpa.dupe(u8, it.next() orelse "");
                const model = try gpa.dupe(u8, it.next() orelse "mock");
                return worker.run(gpa, io, init.environ_map, run_dir, nbin, model);
            }
            // Manual, no-server exercise of the shared headless-browser layer (launch → CDP → navigate →
            // snapshot → screenshot). Short-circuits like `worker` because it needs the real threaded io +
            // environ, not the thin CLI client.
            if (std.mem.eql(u8, sub, "browser-smoke")) {
                const url = try gpa.dupe(u8, it.next() orelse "https://example.com");
                @import("worker/browser/session.zig").smoke(gpa, io, init.environ_map, url);
                return;
            }
            // Per-machine local-host daemon (round 2): owns the client's browser (+ later MCP) sessions behind
            // the loopback broker so the desk's subprocess-per-tool delegation shares ONE session. Idle-exits.
            if (std.mem.eql(u8, sub, "local-host")) {
                @import("worker/browser/host.zig").runDaemon(gpa, io, init.environ_map);
                return;
            }
            cli_sub = try gpa.dupe(u8, sub);
            if (std.mem.eql(u8, sub, "--desk")) desktop_mode = true;
            if (isServerOnly(sub)) desktop_mode = false;
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--desk")) desktop_mode = true;
                if (isServerOnly(arg)) desktop_mode = false;
                cli_args.append(gpa, try gpa.dupe(u8, arg)) catch {};
            }
        }
    } else |_| {}

    var paths = try resolvePaths(gpa, io);
    if (init.environ_map.get("NEURON_LOOPS_DATA")) |d| {
        if (d.len > 0) paths.data = try gpa.dupe(u8, d);
    }
    _ = std.Io.Dir.cwd().createDirPathStatus(io, paths.data, .default_dir) catch {};

    // The one place the port is resolved (CLI client + server bind share it): NL_PORT else 8787.
    const cli_port: u16 = if (init.environ_map.get("NL_PORT")) |v|
        (std.fmt.parseInt(u16, std.mem.trim(u8, v, " \r\n\t"), 10) catch 8787)
    else
        8787;

    // Single-process exercise of the Feature 2 browser tools (dispatch + gate + persistent session manager);
    // needs the real io + environ, so it short-circuits here like `worker`/`browser-smoke`.
    if (std.mem.eql(u8, cli_sub, "browser-flow-smoke")) {
        const url = if (cli_args.items.len > 0) cli_args.items[0] else "https://example.com";
        @import("cli/exec_tool.zig").browserFlowSmoke(gpa, io, init.environ_map, paths.home, paths.data, url);
        return;
    }
    if (std.mem.eql(u8, cli_sub, "browser-invent-smoke")) {
        const url = if (cli_args.items.len > 0) cli_args.items[0] else "https://example.com";
        @import("cli/exec_tool.zig").browserInventSmoke(gpa, io, init.environ_map, paths.home, paths.data, url);
        return;
    }
    if (std.mem.eql(u8, cli_sub, "pixel-smoke")) {
        const url = if (cli_args.items.len > 0) cli_args.items[0] else "https://example.com";
        const query = if (cli_args.items.len > 1) cli_args.items[1] else "documentation examples";
        @import("cli/exec_tool.zig").pixelSmoke(gpa, io, init.environ_map, paths.home, paths.data, url, query);
        return;
    }
    if (std.mem.eql(u8, cli_sub, "mcp-smoke")) {
        @import("cli/exec_tool.zig").mcpSmoke(gpa, io, init.environ_map, paths.home, paths.data);
        return;
    }
    if (std.mem.eql(u8, cli_sub, "mcp-invent-smoke")) {
        @import("cli/exec_tool.zig").mcpInventSmoke(gpa, io, init.environ_map, paths.home, paths.data);
        return;
    }

    // CLI CLIENT: a recognized verb dispatches to the command-line client (a thin /api/v1/* caller) and exits.
    // This is the surface that retires the Python launcher — the server is the daemon, the CLI is its client.
    if (cli_sub.len > 0 and cli.isCommand(cli_sub)) {
        var cctx = cli.Ctx{ .gpa = gpa, .io = io, .data = paths.data, .home = paths.home, .port = cli_port, .environ = init.environ_map };
        return std.process.exit(cli.dispatch(&cctx, cli_sub, cli_args.items));
    }

    // DOUBLE-CLICK CONSOLE (Windows, app mode only). Past this point no CLI verb can be running and every
    // `return` above has already fired, so the only callers left are the one-click default and an explicit
    // `--desk`. If we own this console outright we hand the work to a windowless copy of ourselves and leave;
    // if a shell is attached, detachOwnConsole is a no-op and we carry on in the dev's terminal. Placed here,
    // before any of the heavy boot below, so the parent exits instantly instead of double-booting the server.
    if (desktop_mode and detachOwnConsole(gpa, io, init.environ_map, cli_sub, cli_args.items)) return std.process.exit(0);

    // Make local Ollama parallel + right-sized on launch (crucial for cast/chat steering; see tuneOllama).
    tuneOllama(gpa, io, init.environ_map);

    const auth_db = try std.fmt.allocPrint(gpa, "{s}/auth.sqlite", .{paths.data});
    const nb = Neuron.init(gpa, io, paths.neuron_bin, auth_db);
    var auth = Auth.init(gpa, nb);
    var ledger = @import("plan/neurons.zig").NeuronLedger.init(gpa, nb);
    var api_keys = @import("auth/api_keys.zig").ApiKeys.init(gpa, nb);
    api_keys.warm() catch |e| log.warn("api_keys warm: {t}", .{e});
    auth.setAdminEmail(init.environ_map.get("NL_ADMIN_EMAIL"));
    auth.warm() catch |e| log.warn("auth warm: {t}", .{e});
    const bind_all = if (init.environ_map.get("NL_BIND")) |v| v.len > 0 and !std.mem.eql(u8, v, "127.0.0.1") else false;
    var apw_buf: [48]u8 = undefined;
    const admin_pw: ?[]const u8 = init.environ_map.get("NL_ADMIN_PASSWORD") orelse blk: {
        if (!bind_all) break :blk null;
        var raw: [24]u8 = undefined;
        io.random(&raw);
        const hx = std.fmt.bytesToHex(raw, .lower);
        @memcpy(apw_buf[0..hx.len], &hx);
        log.warn("*** NL_ADMIN_PASSWORD unset on a public bind — generated admin password: {s}\n*** SAVE THIS NOW (shown once); set NL_ADMIN_PASSWORD to pin a stable one. ***", .{apw_buf[0..hx.len]});
        break :blk apw_buf[0..hx.len];
    };
    auth.seedDefaultAdmin(admin_pw);
    var sup = Supervisor.init(gpa, io, paths.neuron_bin);
    sup.server_key = crypto.deriveServerKey(gpa, io, init.environ_map, paths.data);
    sup.parent_env = init.environ_map;
    sup.ledger = &ledger;
    const readopted = sup.reattach(paths.data);
    const retention_days: u32 = if (init.environ_map.get("NL_RETENTION_DAYS")) |v| (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch 14) else 14;
    // BYOK rate limiter: optional per-provider requests/min cap. Unset/0 = unlimited (the 429 cooldown is always
    // active regardless). Local models never rate-limit, so this only ever shapes hosted traffic.
    rate.configure(if (init.environ_map.get("NL_RATE_RPM")) |v| (std.fmt.parseInt(i32, std.mem.trim(u8, v, " \r\n\t"), 10) catch 0) else 0);
    if (retention_days > 0) {
        const swept = sup.pruneOldRuns(paths.data, retention_days);
        if (swept > 0) log.info("retention: pruned {d} stale run dir(s) at startup (>= {d}d inactive)", .{ swept, retention_days });
    }
    // Swarm reconcile + retention GC run on a BACKGROUND thread, never on an httpz request thread — reconcile
    // can spawn a worker subprocess (respawn) which, inline in a /fleet or list handler, starves the pool and
    // wedges the server. Handlers now only read the in-memory roster.
    sup.gc_data_dir = paths.data;
    sup.gc_days = retention_days;
    if (std.Thread.spawn(.{}, Supervisor.bgLoop, .{&sup})) |t| t.detach() else |_| {}
    var audit = AuditLog.init(gpa, io, paths.data);
    var login_guard = LoginGuard.init(gpa, io);
    var vault = KeyVault.init(gpa, io, nb, sup.server_key);

    const open_reg = if (init.environ_map.get("NL_OPEN_REGISTRATION")) |v|
        (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on"))
    else
        false;
    const cf_account = init.environ_map.get("NL_CF_ACCOUNT_ID") orelse "";
    const wai_token = init.environ_map.get("NL_WORKERS_AI_TOKEN") orelse "";
    const production = if (init.environ_map.get("NL_PRODUCTION")) |v|
        (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on"))
    else
        false;
    // Cloudflare OAuth (self-managed public client): env-overridable so a deployment bakes only its public
    // client_id. The redirect defaults to this server's loopback callback on the resolved port.
    const cf_oauth_redirect = init.environ_map.get("NL_CF_OAUTH_REDIRECT") orelse
        (std.fmt.allocPrint(gpa, "http://localhost:{d}/api/v1/oauth/cloudflare/callback", .{cli_port}) catch "http://localhost:8787/api/v1/oauth/cloudflare/callback");
    var app = App{ .gpa = gpa, .io = io, .auth = &auth, .sup = &sup, .audit = &audit, .login_guard = &login_guard, .vault = &vault, .data = paths.data, .server_key = sup.server_key, .open_registration = open_reg, .cf_account_id = cf_account, .workers_ai_token = wai_token, .retention_days = retention_days, .production = production, .ledger = &ledger, .keys = &api_keys, .cf_oauth_client_id = init.environ_map.get("NL_CF_OAUTH_CLIENT_ID") orelse cf_oauth.DEFAULT_CLIENT_ID, .cf_oauth_scopes = init.environ_map.get("NL_CF_OAUTH_SCOPES") orelse "account:read ai:write offline_access", .cf_oauth_redirect = cf_oauth_redirect, .cf_oauth_auth_url = init.environ_map.get("NL_CF_OAUTH_AUTH_URL") orelse "https://dash.cloudflare.com/oauth2/auth", .cf_oauth_token_url = init.environ_map.get("NL_CF_OAUTH_TOKEN_URL") orelse "https://dash.cloudflare.com/oauth2/token", .cf_oauth_accounts_url = init.environ_map.get("NL_CF_OAUTH_ACCOUNTS_URL") orelse "https://api.cloudflare.com/client/v4/accounts" };
    // SCHEDULED TASKS run on their own background thread (the second one beside Supervisor.bgLoop, same ~5s
    // cadence): a due task spawns a full chat turn, which must never ride an httpz request thread. Spawned here
    // — not next to the sup.bgLoop spawn above — because it needs the fully-wired App; like sup, `app` lives on
    // main's stack for the life of the process (listen() below never returns in normal operation).
    if (std.Thread.spawn(.{}, sched.bgLoop, .{&app})) |t| t.detach() else |_| {}
    log.info("billing: {s} (NL_PRODUCTION)", .{if (production) "PRODUCTION — non-admins metered by neuron plan" else "BETA — unmetered full use"});
    if (!open_reg) log.info("registration: CLOSED (private beta) — set NL_OPEN_REGISTRATION=1 to open public signups", .{});
    if (cf_account.len > 0 and wai_token.len > 0) log.info("Workers AI: ENABLED (backbone) — provider \"workers-ai\" runs on the Cloudflare account's inference endpoint", .{}) else log.info("Workers AI: not configured (set NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN to enable the backbone)", .{});

    const port = cli_port; // resolved once above (NL_PORT else 8787), shared with the CLI client
    // On Windows httpz runs the BLOCKING thread-per-connection worker (one pool thread per live socket),
    // and its ONLY idle/half-open reaping is SO_RCVTIMEO — which is never set unless we pass timeouts here.
    // Without these, a keep-alive connection that dies without a clean FIN (laptop sleep, tab crash, network
    // blip) strands its pool thread forever; enough of them starve the 32-thread pool and fresh casts fail
    // with curl status 000. keepalive=60 reaps idle sockets; request=15 caps slow/half-sent requests;
    // request_count recycles a connection after N requests so no single socket lives unboundedly.
    var server = try httpz.Server(*App).init(io, gpa, .{
        .address = if (bind_all) .all(port) else .localhost(port),
        // request_count = 1: close the connection after every response (the Connection: close path). This
        // stops a half-closed keepalive socket from lingering in httpz's blocking worker, where recv()==0 on a
        // FIN'd peer returns "not done, no error" forever and pins a pool thread at 100% CPU. Every client here
        // is localhost (desktop netcli already sends Connection: close; the web UI reconnects), so the extra
        // handshake per request is free.
        .timeout = .{ .request = 15, .keepalive = 60, .request_count = 1 },
        // Body cap: httpz defaults to 1 MiB, which 413-rejects a chat message carrying an image attachment
        // (base64 of a normal screenshot easily exceeds 1 MiB) BEFORE the handler runs. Lift it to 16 MiB —
        // above the desk's 8 MiB raw-image read limit × ~1.4 base64 + JSON/header headroom. Loopback-only.
        .request = .{ .max_body_size = 16 << 20 },
        // httpz here runs the BLOCKING worker model (thread-per-request); a cast/deploy handler holds its pool
        // thread for the whole synchronous spawn. The 32-thread default starves under a burst of concurrent
        // casts (each also leaving a live worker behind) — new casts then hang + return curl 000. Give admission
        // real headroom so a handful of slow spawns can't wedge the pool. (The worker-CPU amplifier is bounded
        // separately by the live-swarm cap in deployCore + the worker's unreachable-LLM backoff.)
        .thread_pool = .{ .count = 128 },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }
    var router = try server.router(.{});
    router.get("/", staticIndex, .{});
    router.get("/app.js", staticJs, .{});
    router.get("/styles.css", staticCss, .{});
    router.get("/models.json", staticModels, .{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/fleet", fleet, .{});
    router.post("/api/v1/auth/register", auth_api.register, .{});
    router.post("/api/v1/auth/login", auth_api.login, .{});
    router.post("/api/v1/auth/logout", auth_api.logout, .{});
    router.get("/api/v1/auth/me", auth_api.me, .{});
    router.post("/api/v1/apikeys", auth_api.keyCreate, .{});
    router.get("/api/v1/apikeys", auth_api.keyList, .{});
    router.delete("/api/v1/apikeys/:id", auth_api.keyRevoke, .{});
    router.post("/api/v1/run", deploy_service.run, .{});
    router.post("/api/v1/cast", deploy_service.cast, .{});
    router.post("/api/v1/swarms", deploy_service.deploy, .{});
    router.post("/api/v1/swarms/resolve", deploy_service.resolve, .{});
    router.get("/api/v1/swarms", deploy_service.listSwarms, .{});
    router.post("/api/v1/keys", keys_api.putKey, .{});
    router.get("/api/v1/keys", keys_api.listKeys, .{});
    router.delete("/api/v1/keys/:provider", keys_api.delKey, .{});
    router.post("/api/v1/oauth/cloudflare/start", cf_oauth.start, .{});
    router.get("/api/v1/oauth/cloudflare/callback", cf_oauth.callback, .{});
    router.get("/api/v1/oauth/cloudflare/status", cf_oauth.status, .{});
    router.get("/api/v1/oauth/cloudflare/models", cf_oauth.models, .{});
    router.post("/api/v1/oauth/cloudflare/logout", cf_oauth.logout, .{});
    router.get("/api/v1/swarms/:id/events", tail_fanout.swarmEvents, .{});
    router.get("/api/v1/swarms/:id/stream", tail_fanout.swarmStream, .{});
    router.get("/api/v1/swarms/:id/files", deploy_service.swarmFiles, .{});
    router.get("/api/v1/swarms/:id/bundle", deploy_service.swarmBundle, .{});
    router.get("/api/v1/swarms/:id/archive", deploy_service.swarmArchive, .{});
    router.get("/api/v1/swarms/:id/file", deploy_service.swarmFile, .{});
    router.put("/api/v1/swarms/:id/file", deploy_service.swarmFilePut, .{});
    router.get("/api/v1/swarms/:id/site/*", deploy_service.swarmSite, .{});
    router.post("/api/v1/swarms/:id/deploy/cloudflare", deploy_service.swarmDeployCf, .{});
    router.post("/api/v1/swarms/:id/control", control_writer.swarmControl, .{});
    router.post("/api/v1/chat/tool", chat_tools.chatTool, .{});
    router.get("/api/v1/chat/convs", chat_service.listConvs, .{});
    router.get("/api/v1/chat/convs/:id", chat_service.getConv, .{});
    router.delete("/api/v1/chat/convs/:id", chat_service.deleteConv, .{});
    router.get("/api/v1/chat/convs/:id/events", chat_service.convEvents, .{});
    router.post("/api/v1/chat/convs/:id/messages", chat_service.postMessage, .{});
    router.post("/api/v1/chat/convs/:id/control", chat_service.chatControl, .{});
    router.post("/api/v1/chat/convs/:id/tool_result", chat_service.toolResult, .{});
    router.get("/api/v1/sched", sched.listTasks, .{});
    router.post("/api/v1/sched", sched.createTask, .{});
    router.post("/api/v1/sched/:id", sched.updateTask, .{});
    router.delete("/api/v1/sched/:id", sched.deleteTask, .{});
    router.post("/api/v1/sched/:id/run", sched.runTaskNow, .{});
    router.get("/api/v1/metrics/llm", metrics.getLlm, .{});
    router.delete("/api/v1/swarms/:id", deploy_service.swarmDelete, .{});
    router.post("/api/v1/billing/checkout", billing_seam.billingCheckout, .{});
    router.get("/api/v1/admin/users", admin_service.adminUsers, .{});
    router.post("/api/v1/admin/billing", deploy_service.adminBilling, .{});
    router.post("/api/v1/admin/users/moderate", admin_service.adminModerate, .{});
    router.get("/api/v1/admin/swarms", admin_service.adminSwarms, .{});
    router.delete("/api/v1/admin/swarms/:id", admin_service.adminKill, .{});
    router.get("/api/v1/admin/audit", admin_service.adminAudit, .{});

    log.info("neuron-loops {s} on http://127.0.0.1:{d}  home={s}  ({d} users, {d} swarms re-adopted)", .{ VERSION, port, paths.home, auth.userCount(), readopted });
    // On a local bind, mint an admin API key and drop it where the desktop reads it, so veil-desk connects
    // and can deploy WITHOUT the user pasting a key. Localhost-only (never on a public bind).
    if (!bind_all) preloadDesktopKey(gpa, io, &auth, &api_keys, init.environ_map, paths.data);
    // APP MODE owns the desk's lifetime. The job goes up FIRST so the desk (and every worker spawned after it)
    // is born inside it. Then, if we actually spawned a desk, a watcher thread turns "user closed the desk"
    // into a clean server shutdown — the fix for the orphaned :8787 server with no UI and no way to stop it.
    // None of this runs under --server-only, and none of it runs if the desk was already up on its own: we
    // only ever wait on a child WE spawned.
    if (desktop_mode) {
        ownProcessTree(init.environ_map);
        if (launchDesktop(gpa, io, paths.home, init.environ_map)) |child| watchDesk(gpa, io, child, &server);
    }
    try server.listen();
}

const DEFAULT_ADMIN_EMAIL = "admin@neuron-loops.local";

/// Ensure a valid admin API key sits at <data>/.desktop_key so the desktop auto-connects. Reuses the
/// existing key if it still verifies; otherwise logs in as the admin, mints one, and writes it. Best-effort.
fn preloadDesktopKey(gpa: std.mem.Allocator, io: std.Io, auth: *Auth, keys: *@import("auth/api_keys.zig").ApiKeys, environ: *std.process.Environ.Map, data: []const u8) void {
    // Written on any localhost bind (harmless, same-user) so the desktop connects whether it's auto-hosted
    // or the user launches it later — NOT gated on NL_NO_DESKTOP.
    const path = std.fmt.allocPrint(gpa, "{s}/.desktop_key", .{data}) catch return;
    defer gpa.free(path);
    // reuse an existing valid key
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256))) |old| {
        defer gpa.free(old);
        if (keys.verify(std.mem.trim(u8, old, " \r\n\t")) != null) return;
    } else |_| {}
    const email = environ.get("NL_ADMIN_EMAIL") orelse DEFAULT_ADMIN_EMAIL;
    const pw = environ.get("NL_ADMIN_PASSWORD") orelse "changeme";
    const tok = auth.login(email, pw) catch return;
    defer gpa.free(tok);
    const u = auth.whoami(tok) orelse return;
    const key = keys.create(u.id, "veil-desk") catch return;
    defer gpa.free(key);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = key }) catch return;
    log.info("veil-desk: preloaded an admin API key at <data>/.desktop_key (localhost)", .{});
}

const DESK_EXE = if (builtin.os.tag == .windows) "veil-desk.exe" else "veil-desk";

/// "Host the desktop": when desktop mode is requested (`--desk`, or the one-click default), launch the
/// veil-desk dashboard if it was built (desk/zig-out/bin/veil-desk) so it sits in the tray and lights up on
/// the server. Best-effort — a headless box either has no binary (built with -Ddesk=false) or no display, and
/// the spawn simply fails without touching the server. Opt out with NL_NO_DESKTOP=1.
///
/// Returns the child so the caller can OWN its lifetime (see watchDesk); null means no desk of ours is
/// running, and the caller must not shut anything down on its account.
fn launchDesktop(gpa: std.mem.Allocator, io: std.Io, home: []const u8, environ: *std.process.Environ.Map) ?std.process.Child {
    if (environ.get("NL_NO_DESKTOP")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return null;
    }
    // Two layouts host the desktop: a release BUNDLE puts veil-desk right next to the server, and a
    // dev CHECKOUT builds it under desk/zig-out/bin. Try the bundle path first, then the checkout path.
    const bundle = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, DESK_EXE }) catch return null;
    defer gpa.free(bundle);
    const checkout = std.fmt.allocPrint(gpa, "{s}/desk/zig-out/bin/{s}", .{ home, DESK_EXE }) catch return null;
    defer gpa.free(checkout);
    const bin = if (std.Io.Dir.cwd().access(io, bundle, .{})) |_|
        bundle
    else |_| if (std.Io.Dir.cwd().access(io, checkout, .{})) |_|
        checkout
    else |_| {
        // NOT SILENT. A user who double-clicked the standalone server binary used to get a blank console and
        // conclude the release was broken. Name the situation instead.
        log.warn("no {s} next to this binary — this is the SERVER-ONLY build, so there is no desktop UI to open. The server itself is up (see the URL above); for the app, use the full bundle that ships {s} alongside {s}, or pass --server-only to silence this.", .{ DESK_EXE, DESK_EXE, if (builtin.os.tag == .windows) "veil.exe" else "veil" });
        return null; // not built in either layout → nothing to host
    };
    const child = std.process.spawn(io, .{ .argv = &.{bin}, .cwd = .{ .path = home }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |e| {
        log.warn("veil-desk: found {s} but could not launch it ({t}) — the server is up, open http://127.0.0.1:8787 in a browser instead", .{ bin, e });
        return null;
    };
    log.info("veil-desk: launched the desktop dashboard (set NL_NO_DESKTOP=1 to disable)", .{});
    return child;
}

/// Ties the server's life to the desk WE spawned: wait on the child, and when it exits, stop httpz and go
/// away. Without this, closing the desk left a headless server holding :8787 with no UI and no ordinary way
/// to stop it. Only ever constructed in app mode, and only for a child we launched ourselves.
const DeskWatch = struct {
    io: std.Io,
    child: std.process.Child,
    server: *httpz.Server(*App),

    fn run(self: *DeskWatch) void {
        if (builtin.os.tag == .windows) {
            // Raw WaitForSingleObject on the child's hProcess rather than Child.wait: this is a plain
            // std.Thread, not an Io task, and the handle is exactly what we need to block on.
            if (self.child.id) |h| _ = winapp.WaitForSingleObject(h, winapp.INFINITE) else return;
        } else {
            _ = self.child.wait(self.io) catch return;
        }
        log.info("veil-desk closed — shutting down (app mode: the desk's window IS the app's lifetime). Use --server-only to run the server without a desk.", .{});
        self.server.stop(); // unblocks listen() in main, which then unwinds and exits normally
        // BACKSTOP. If listen() somehow does not unwind, exit anyway — leaving the orphaned server behind is
        // the exact bug this whole path exists to kill. On Windows the job object then reaps the children.
        threadSleepMs(self.io, 3000);
        std.process.exit(0);
    }
};

fn watchDesk(gpa: std.mem.Allocator, io: std.Io, child: std.process.Child, server: *httpz.Server(*App)) void {
    // Heap-allocated and intentionally never freed: it outlives this call and lives until the process exits.
    const w = gpa.create(DeskWatch) catch return;
    w.* = .{ .io = io, .child = child, .server = server };
    if (std.Thread.spawn(.{}, DeskWatch.run, .{w})) |t| t.detach() else |e| {
        gpa.destroy(w);
        log.warn("veil-desk: could not start the exit watcher ({t}) — closing the desk will leave the server running; stop it from the tray or Task Manager", .{e});
    }
}

fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true, .service = "veil", .version = VERSION }, .{});
}

const INSTANCE_MIND_CAP = 25;

fn fleet(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const l = app.sup.load();
    const headroom = if (l.live_minds < INSTANCE_MIND_CAP) INSTANCE_MIND_CAP - l.live_minds else 0;
    try res.json(.{
        .ok = true,
        .version = VERSION,
        .swarms = l.swarms,
        .live_swarms = l.live_swarms,
        .live_minds = l.live_minds,
        .mind_capacity = INSTANCE_MIND_CAP,
        .headroom = headroom,
        .saturated = headroom == 0,
    }, .{});
}

fn staticIndex(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_HTML;
}
fn staticJs(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_JS;
}
fn staticCss(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_CSS;
}
fn staticModels(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = ASSET_MODELS;
}
