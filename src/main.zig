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
const browser_ext_api = @import("worker/browser/ext_api.zig");
const chat_service = @import("worker/chat/service.zig");
const sched = @import("worker/sched.zig");
const metrics = @import("worker/metrics.zig");
const rate = @import("worker/rate.zig");
const admin_service = @import("admin/admin_service.zig");
const billing_seam = @import("plan/billing_seam.zig");
const keys_api = @import("config/keys_api.zig");
const local_models = @import("config/local_models.zig");
const cf_oauth = @import("config/cf_oauth.zig");
const server_config = @import("config/server_config.zig");
const lan_mod = @import("config/lan.zig");
const worker = @import("worker/run.zig");
const tools = @import("worker/tools.zig");
const deps = @import("worker/deps.zig");
const cli = @import("cli.zig");
const build_options = @import("build_options");

const recipes = @import("worker/recipes.zig");
const plugins = @import("plug/plugins.zig");
const plug_theme = @import("plug/theme.zig");

/// Whether the desktop GUI is compiled into this binary (`-Dapp`, default true). False = the server-only
/// build: no raylib, no GL/X11, and no `desk` module in the graph at all — hence the comptime branch, which
/// keeps @import("desk") out of the server-only compilation entirely.
pub const HAS_GUI = build_options.gui;
const desk = if (HAS_GUI) @import("desk") else struct {};

/// Whether the BUILT-IN model engine is compiled into this binary (`-Dbuiltin`, default true).
/// False keeps llamaeng's C externs (and the whole embedded inference library) out of the build;
/// the endpoint/downloader/status modules compile either way and honestly report "unavailable".
pub const HAS_BUILTIN = build_options.builtin;
const llamaeng = if (HAS_BUILTIN) @import("worker/llamaeng.zig") else struct {};
const builtin_state = @import("worker/builtin.zig");
const builtin_endpoint = @import("worker/builtin_endpoint.zig");
const modelpull = @import("worker/modelpull.zig");

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

/// One embedded static asset plus everything prepareStatics derives from it at boot: a gzip of the body and
/// the entity tags naming each representation. Written once before the server listens, read by every
/// request thread after — which is the whole reason it needs no lock.
const StaticAsset = struct {
    body: []const u8,
    /// null = gzip failed or did not pay; serve identity and never mention the encoding.
    gz: ?[]const u8 = null,
    /// Empty = tag generation failed. serveStatic must then skip conditional GET entirely (see there).
    etag: []const u8 = "",
    etag_gz: []const u8 = "",
};

var static_html: StaticAsset = .{ .body = ASSET_HTML };
var static_js: StaticAsset = .{ .body = ASSET_JS };
var static_css: StaticAsset = .{ .body = ASSET_CSS };
var static_models: StaticAsset = .{ .body = ASSET_MODELS };

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
    /// The only channel guaranteed to reach a double-clicked veil's user: it has no console (see
    /// detachOwnConsole) and, in the case this is used for, no window either.
    extern "user32" fn MessageBoxA(hWnd: ?*anyopaque, text: [*:0]const u8, caption: [*:0]const u8, uType: u32) callconv(.winapi) c_int;
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
    // shipped binary is a single icon that brings the whole app up. `--server-only` (alias `--headless`) keeps
    // the server-only behaviour for headless boxes, service managers, and every internal auto-start that
    // launches its own UI (cli.zig ensureServer and restart-veil.ps1 both pass it). CLI verbs are unaffected:
    // they run and return well before the server (and therefore the desk) is ever started.
    //
    // In a `-Dapp=false` build there is no GUI to open, so this is pinned false and every `veil` invocation
    // behaves exactly like --server-only.
    var desktop_mode = HAS_GUI;
    var desk_requested = false; // an explicit --desk, so a server-only build can say why it did nothing
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
    // async_limit: Threaded defaults to cpu_count-1 concurrent async tasks, and AT the limit io.async runs the
    // task INLINE ON THE CALLER — httpc's timeout race then sleeps/blocks the calling thread (unbounded when the
    // request leg runs unwatched), which froze the merged GUI+server process solid during tool-heavy turns: a
    // losing race timer holds its slot for its full 5-8s on Windows (blocked sockets can't be canceled at all),
    // so ordinary chat traffic pinned the pool at saturation and every caller degraded to serial inline waits.
    // Threads spawn on demand only, so a high ceiling costs nothing when quiet.
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ, .async_limit = .limited(512) });
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
            if (std.mem.eql(u8, sub, "--desk")) {
                desk_requested = true;
                desktop_mode = HAS_GUI;
            }
            if (isServerOnly(sub)) desktop_mode = false;
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--desk")) {
                    desk_requested = true;
                    desktop_mode = HAS_GUI;
                }
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

    // LOCAL KNOWLEDGE MIRROR (server process): chat/cast tools route through the same fetch layer as swarm
    // workers, so adopting a local pack corpus here makes desk research serve from disk too. Workers detect
    // it independently (their own process); placed after the CLI early-returns so a thin verb never pays
    // the manifest parse.
    if (@import("worker/ragmirror.zig").initAt(gpa, io, init.environ_map, paths.data)) {
        log.info("knowledge mirror: {s} (+{d} atlas domains)", .{ @import("worker/ragmirror.zig").root(), @import("worker/locs/atlas.zig").extension().len });
    }

    const auth_db = try std.fmt.allocPrint(gpa, "{s}/auth.sqlite", .{paths.data});
    const nb = Neuron.init(gpa, io, paths.neuron_bin, auth_db);
    var auth = Auth.init(gpa, nb);
    var ledger = @import("plan/neurons.zig").NeuronLedger.init(gpa, nb);
    var api_keys = @import("auth/api_keys.zig").ApiKeys.init(gpa, nb);
    api_keys.warm() catch |e| log.warn("api_keys warm: {t}", .{e});
    auth.setAdminEmail(init.environ_map.get("NL_ADMIN_EMAIL"));
    auth.warm() catch |e| log.warn("auth warm: {t}", .{e});
    // BIND 0.0.0.0 BY DEFAULT. The veil is meant to be reachable from the other machines around it —
    // a phone on the sofa, a laptop in the next room — and a loopback default meant every one of those
    // people had to discover NL_BIND before the web UI existed for them at all. `NL_BIND=127.0.0.1`
    // still pins it to this machine.
    //
    // This flag used to decide THREE unrelated things. It now decides one — the listen address. The
    // other two moved to what actually motivates them: the desktop key is minted for the local clients
    // that need it (gating that on the bind address silently broke the desk and CLI), and the admin
    // password is randomised when the box is reachable AND nobody chose one.
    const bind_all = if (init.environ_map.get("NL_BIND")) |v|
        !(std.mem.eql(u8, v, "127.0.0.1") or std.mem.eql(u8, v, "localhost"))
    else
        true;
    var apw_buf: [48]u8 = undefined;
    var apw_generated = false;
    const admin_pw: ?[]const u8 = init.environ_map.get("NL_ADMIN_PASSWORD") orelse blk: {
        if (!bind_all) break :blk null;
        // REACHABLE + no password chosen. The shipped default is "changeme", published in the README,
        // and this program runs arbitrary code as the user who started it — so a known password on a
        // box answering the whole subnet is a full host compromise by anyone on the same wifi.
        //
        // REUSE what we generated last time before minting anything. Generating unconditionally meant a
        // fresh secret every boot while seedDefaultAdmin quietly discarded it (register returns
        // EmailTaken for an existing account and the caller returns), so from boot 2 the recorded
        // password was never the real one — and on an upgraded install the real one was still
        // "changeme" while the file said otherwise. Reassuring and wrong beats loud and right only in
        // the sense that nobody notices.
        if (readAdminPassword(io, paths.data, &apw_buf)) |saved| break :blk saved;
        var raw: [24]u8 = undefined;
        io.random(&raw);
        const hx = std.fmt.bytesToHex(raw, .lower);
        @memcpy(apw_buf[0..hx.len], &hx);
        apw_generated = true;
        break :blk apw_buf[0..hx.len];
    };
    // How many requests one keep-alive socket serves before recycling. See the timeout block below.
    const keepalive_requests: u32 = if (init.environ_map.get("NL_KEEPALIVE_REQUESTS")) |v|
        (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch 200)
    else
        200;

    // How many turns this box runs at once, and how many any one account may hold. Defaults suit a
    // shared server; the right numbers depend on the rate limit of the provider key everyone shares.
    chat_service.configureTurnLimits(init.environ_map);

    auth.seedDefaultAdmin(admin_pw);

    // MAKE IT TRUE, then record it. seedDefaultAdmin only CREATES; against an existing account it
    // returns having changed nothing. So prove the password actually works, rotate it if not, and only
    // then write it down — a file that states a password which was never applied is worse than no file,
    // because the reader stops looking for the real problem.
    if (admin_pw) |pw| {
        if (init.environ_map.get("NL_ADMIN_PASSWORD") == null) {
            const email = init.environ_map.get("NL_ADMIN_EMAIL") orelse DEFAULT_ADMIN_EMAIL;
            var in_force = false;
            if (auth.login(email, pw)) |tok| {
                gpa.free(tok);
                in_force = true;
            } else |_| {
                // Not in force: either an account that predates this (still on the shipped default) or
                // a data dir whose recorded password no longer matches. Rotate it.
                in_force = auth.setPassword(email, pw);
                if (in_force) apw_generated = true; // changed → the user needs to be told again
            }
            if (!in_force) {
                log.err("could not set an admin password on {s} — it may still be the shipped default. Set NL_ADMIN_PASSWORD.", .{email});
            } else if (apw_generated) {
                writeAdminPassword(gpa, io, paths.data, pw);
                log.warn("*** no NL_ADMIN_PASSWORD set and this server is reachable on the network.\n" ++
                    "*** Admin password: {s}\n" ++
                    "*** Saved to {s}/admin-password.txt — set NL_ADMIN_PASSWORD to pin your own.", .{ pw, paths.data });
            }
        }
    }

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
    // Admin-owned runtime settings. The env vars seed it on a fresh install; after that the admin
    // sets it from the web UI and it persists, so a stale launch script cannot undo them on restart.
    var server_cfg = server_config.ServerConfig.init(gpa, io, paths.data);

    // Recipes are immutable once loaded. The admin API writes them to {data}/tools; a service restart picks up
    // the new registry, keeping every in-flight turn's borrowed recipe pointers stable.
    const recipe_dir = try std.fmt.allocPrint(gpa, "{s}/tools", .{paths.data});
    defer gpa.free(recipe_dir);
    const recipe_registry = try gpa.create(recipes.Registry);
    recipe_registry.* = recipes.loadDir(gpa, io, recipe_dir, &tools.isBuiltinTool);
    defer {
        recipe_registry.deinit();
        gpa.destroy(recipe_registry);
    }

    // PLUGINS + THEMES: the user-extension layer. Loaded once at startup from {data}/plugins/*/plugin.lua
    // (each a sandboxed Lua manifest) and {data}/themes/*.lua (the shared theme workspace, seeded with the
    // shipped dark/light/matrix themes on first boot). Like recipes it is immutable once loaded and never
    // freed in place — a reload rebuilds and pointer-swaps. Never fails: a broken plugin loads as
    // state=failed with its error kept, so one bad extension can't stop the server.
    const plug_registry = plugins.loadAll(gpa, io, init.environ_map, paths.data, .{});
    log.info("plugins: {d} loaded, {d} themes in workspace", .{ plug_registry.count(), plug_registry.themes.count });

    // ---- the BUILT-IN model engine: weights store + loopback dialect endpoint ----
    // The plug-and-play tier: the server serves the-veil-12b itself. builtin_state owns the store
    // ({data}/models or NL_MODELS_DIR) and the per-boot bearer; the endpoint is a separate
    // loopback-only listener because swarm minds are subprocesses and reach it over TCP; the
    // catalog's `builtin` provider carries a sentinel base that deploy/chat resolution swaps for
    // the live endpoint. In a -Dbuiltin=false build everything below still answers status routes —
    // it just reports compiled:false and resolution says unavailable.
    builtin_state.init(io, init.environ_map, paths.data);
    modelpull.configure(gpa, io, init.environ_map);
    if (comptime HAS_BUILTIN) {
        llamaeng.configure(gpa, io, init.environ_map, builtin_state.modelPath());
        modelpull.on_store_change = builtinStoreChanged;
        modelpull.on_before_swap = builtinBeforeSwap;
        if (builtin_endpoint.start(gpa, io, llamaeng.engine(), init.environ_map)) |bport| {
            const winf = llamaeng.info();
            log.info("built-in model engine: {s} on 127.0.0.1:{d}{s} (weights: {s})", .{ builtin_state.MODEL_ID, bport, builtin_state.PATH_PREFIX, @tagName(winf.state) });
        } else |e| {
            log.warn("built-in model engine endpoint failed to start ({t}) — the builtin provider will resolve unavailable", .{e});
        }
        if (builtin_state.syncedDirWarning())
            log.warn("models dir sits under a cloud-synced folder — set NL_MODELS_DIR to a local path so multi-GB weights stay out of sync churn", .{});
    } else {
        log.info("built-in model engine: not compiled in (-Dbuiltin=false)", .{});
    }

    var app = App{ .gpa = gpa, .io = io, .auth = &auth, .sup = &sup, .audit = &audit, .login_guard = &login_guard, .vault = &vault, .data = paths.data, .server_key = sup.server_key, .open_registration = open_reg, .cf_account_id = cf_account, .workers_ai_token = wai_token, .retention_days = retention_days, .production = production, .recipes = recipe_registry, .plugs = plug_registry, .ledger = &ledger, .keys = &api_keys, .cf_oauth_client_id = init.environ_map.get("NL_CF_OAUTH_CLIENT_ID") orelse cf_oauth.DEFAULT_CLIENT_ID, .cf_oauth_scopes = init.environ_map.get("NL_CF_OAUTH_SCOPES") orelse "account:read ai:write offline_access", .cf_oauth_redirect = cf_oauth_redirect, .cf_oauth_auth_url = init.environ_map.get("NL_CF_OAUTH_AUTH_URL") orelse "https://dash.cloudflare.com/oauth2/auth", .cf_oauth_token_url = init.environ_map.get("NL_CF_OAUTH_TOKEN_URL") orelse "https://dash.cloudflare.com/oauth2/token", .cf_oauth_accounts_url = init.environ_map.get("NL_CF_OAUTH_ACCOUNTS_URL") orelse "https://api.cloudflare.com/client/v4/accounts", .cfg = &server_cfg };
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
        // KEEP-ALIVE, and why it is no longer 1. This was pinned to 1 — close after every response — to dodge
        // a half-closed keepalive socket pinning an httpz blocking-worker thread at 100% CPU, and the
        // justification was explicit: "every client here is localhost, so the extra handshake per request is
        // free". That premise died when the server started binding every interface. The web client polls a
        // running turn about once a second, so a hundred people on wifi is a hundred TCP+handshake cycles a
        // second, each one a round trip they wait on — the single largest avoidable cost in the whole
        // request path, and it lands hardest on the phone furthest from the router.
        //
        // The original hazard is still real, so it is bounded rather than ignored: request_count caps how
        // many requests one socket may serve before it is recycled, and keepalive=60 still reaps idle ones.
        // A stuck socket therefore costs at most one thread for at most a minute, out of 128 — instead of
        // every client paying a handshake on every poll. Tunable for an operator who hits the old bug.
        .timeout = .{ .request = 15, .keepalive = 60, .request_count = keepalive_requests },
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
    // Before any route can be hit: gzip the embedded assets and mint their ETags once. See prepareStatics.
    prepareStatics(gpa);
    var router = try server.router(.{});
    router.get("/", staticIndex, .{});
    router.get("/app.js", staticJs, .{});
    router.get("/styles.css", staticCss, .{});
    router.get("/models.json", staticModels, .{});
    // PWA (public, like every other shell asset): the manifest is minted from the request's Host so an
    // install binds to the domain the user actually reached — localhost or a public name. See pwaManifest.
    router.get("/manifest.webmanifest", pwaManifest, .{});
    router.get("/sw.js", pwaServiceWorker, .{});
    router.get("/icon.svg", pwaIcon, .{});
    router.get("/icon-maskable.svg", pwaIconMaskable, .{});
    router.get("/api/v1/health", health, .{});
    // What binaries this HOST is missing (python/node/npm/curl/git/browser) and how to fix each — read by
    // the desk + the AI BEFORE a tool spawn, so a missing dep is named up front instead of decoded from a
    // flat "X failed to run" afterward. Authed like /models/local; see healthDeps.
    router.get("/api/v1/health/deps", healthDeps, .{});
    router.get("/api/v1/fleet", fleet, .{});
    // PLUGIN + THEME ECOSYSTEM. /themes is intentionally PUBLIC (no auth): the web app fetches it before
    // login to paint the sign-in screen in the user's chosen theme, exactly as the CSS palette is public.
    // /plugins needs a user (it names the extensions active on their turns). /plugins/reload is admin-only:
    // it rescans {data}/plugins + {data}/themes and pointer-swaps the live registry with no restart.
    router.get("/api/v1/themes", themesList, .{});
    router.get("/api/v1/plugins", pluginsList, .{});
    router.post("/api/v1/plugins/reload", pluginsReload, .{});
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
    // Which local models Ollama has ACTUALLY pulled — the catalog lists what is worth running, not
    // what is installed, and only this machine can answer the difference.
    router.get("/api/v1/models/local", local_models.list, .{});
    // The BUILT-IN model: one status snapshot (weights store + engine + any transfer in flight),
    // and the verbs that change the store. Same requireUser gate as /models/local — all of it is
    // "what can THIS host serve".
    router.get("/api/v1/models/builtin", builtinStatus, .{});
    router.post("/api/v1/models/builtin/pull", builtinPull, .{});
    router.post("/api/v1/models/builtin/cancel", builtinCancel, .{});
    router.post("/api/v1/models/builtin/import", builtinImport, .{});
    router.post("/api/v1/models/builtin/check", builtinCheck, .{});
    router.delete("/api/v1/models/builtin", builtinDelete, .{});
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
    // The browser extension's relay. `hello` is unauthenticated (it is how the extension finds this server at
    // all) and `pair` is loopback-only; the rest carry the pairing token. See worker/browser/ext_api.zig.
    // Load (or mint + persist) the pairing token BEFORE these routes can serve, so a server restart keeps the
    // token an already-paired extension is still holding instead of orphaning it. See ext.loadOrMintToken.
    @import("worker/browser/ext.zig").loadOrMintToken(io, gpa, paths.data);
    router.get("/api/v1/browser/ext/hello", browser_ext_api.hello, .{});
    router.post("/api/v1/browser/ext/pair", browser_ext_api.pair, .{});
    router.get("/api/v1/browser/ext/poll", browser_ext_api.poll, .{});
    router.post("/api/v1/browser/ext/result", browser_ext_api.result, .{});
    router.post("/api/v1/browser/ext/bye", browser_ext_api.bye, .{});
    router.get("/api/v1/browser/ext/status", browser_ext_api.status, .{});
    // The cross-process relay: the desk runs each browser tool in a `veil exec-tool` subprocess that forwards
    // to the local-host daemon, and the extension is attached HERE. These let those processes reach it.
    router.post("/api/v1/browser/ext/live", browser_ext_api.live, .{});
    router.post("/api/v1/browser/ext/relay", browser_ext_api.relay, .{});
    router.get("/api/v1/chat/convs", chat_service.listConvs, .{});
    router.get("/api/v1/chat/convs/:id", chat_service.getConv, .{});
    // What a conversation has BUILT. The desk browses the build tree straight off disk; a browser
    // cannot, so it needs these two. Same pair the swarm side has always had.
    router.get("/api/v1/chat/convs/:id/files", chat_service.convFiles, .{});
    router.get("/api/v1/chat/convs/:id/file", chat_service.convFile, .{});
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
    router.get("/api/v1/admin/recipes", admin_service.adminRecipes, .{});
    router.post("/api/v1/admin/users/:uid/recipes/:name", admin_service.adminSetRecipeGrant, .{});
    router.post("/api/v1/admin/billing", deploy_service.adminBilling, .{});
    router.post("/api/v1/admin/users/moderate", admin_service.adminModerate, .{});
    // Registration defaults CLOSED, which is right for a LAN box but left no way to onboard anyone.
    router.post("/api/v1/admin/users", admin_service.adminCreateUser, .{});
    // The default model every web user falls back to — set from the UI, live, no restart.
    router.get("/api/v1/admin/config", admin_service.adminGetConfig, .{});
    router.post("/api/v1/admin/config", admin_service.adminSetConfig, .{});
    // The instance-wide provider key: a default model nobody can afford to call is not a default.
    router.get("/api/v1/admin/keys", admin_service.adminListKeys, .{});
    router.post("/api/v1/admin/keys", admin_service.adminPutKey, .{});
    router.delete("/api/v1/admin/keys/:provider", admin_service.adminDelKey, .{});
    // Moderation needs to see what an account is DOING. Metadata only — see the handler.
    router.get("/api/v1/admin/users/:uid/activity", admin_service.adminUserActivity, .{});
    router.get("/api/v1/admin/swarms", admin_service.adminSwarms, .{});
    router.delete("/api/v1/admin/swarms/:id", admin_service.adminKill, .{});
    router.get("/api/v1/admin/audit", admin_service.adminAudit, .{});

    // Publish the browser-extension relay to local temp, now that the port is settled. This is what lets a
    // `veil exec-tool` subprocess and the local-host daemon drive the user's own browser instead of quietly
    // launching their own — they attach to no extension themselves, and this is how they find the one here.
    browser_ext_api.becomeHost(gpa, io, init.environ_map, port);

    // Print what it is ACTUALLY reachable at. The banner used to say 127.0.0.1 unconditionally, which was
    // merely misleading on a loopback bind and actively wrong now that binding every interface is the
    // default — the whole point is that somebody on another machine can open it.
    if (bind_all) {
        // Name the addresses somebody can actually type. A placeholder like "http://<this machine>"
        // is not an address, and the whole point of binding every interface is that a phone in the
        // next room can open it.
        var lan_buf: [256]u8 = undefined;
        const lan = lan_mod.addresses(gpa, io, &lan_buf);
        if (lan.len > 0) {
            // One complete URL per address. Joining them with commas and appending the port once
            // produced "http://a, b, c:8787", where only the last one is actually a link.
            var urls_buf: [512]u8 = undefined;
            var un: usize = 0;
            var addrs = std.mem.splitScalar(u8, lan, ' ');
            while (addrs.next()) |a| {
                if (a.len == 0) continue;
                const line = std.fmt.bufPrint(urls_buf[un..], "\n      http://{s}:{d}", .{ a, port }) catch break;
                un += line.len;
            }
            log.info("neuron-loops {s} on http://localhost:{d}\n" ++
                "    open from another machine (phone, laptop) at:{s}\n" ++
                "    home={s}  ({d} users, {d} swarms re-adopted)", .{ VERSION, port, urls_buf[0..un], paths.home, auth.userCount(), readopted });
        } else {
            log.info("neuron-loops {s} on http://localhost:{d}  (also reachable from this network — check this machine's IP)  home={s}  ({d} users, {d} swarms re-adopted)", .{ VERSION, port, paths.home, auth.userCount(), readopted });
        }
    } else {
        log.info("neuron-loops {s} on http://127.0.0.1:{d}  (this machine only — NL_BIND=127.0.0.1)  home={s}  ({d} users, {d} swarms re-adopted)", .{ VERSION, port, paths.home, auth.userCount(), readopted });
    }

    // ALWAYS mint the desktop key. This is how the desk and the `veil` CLI authenticate to their own
    // server on this machine, and it is a file readable only by this OS user — the port being open to
    // the LAN does not make a local file more reachable. Gating it on the bind address meant that
    // turning on network access silently broke every same-machine client.
    preloadDesktopKey(gpa, io, &auth, &api_keys, init.environ_map, paths.data, admin_pw);
    // Carry a pre-split install's stored credentials into the per-user store, once. uid 1 by
    // construction: next_id starts at 1 and the admin is the first account seeded, which is the same
    // assumption engine.zig's legacy read-fallback already makes.
    migrateLegacyMemories(gpa, io, paths.data, 1);
    if (desk_requested and !HAS_GUI)
        log.warn("--desk ignored: this is the SERVER-ONLY build (-Dapp=false), which has no GUI compiled in. The server itself is up (see the URL above) — open it in a browser, or use the standard build.", .{});

    // ---- SERVER-ONLY: today's behaviour, unchanged. listen() blocks main until the process is stopped. ----
    if (!desktop_mode or !HAS_GUI) return server.listen();

    // ---- APP MODE: one process, GUI on the main thread, server on a background thread. ----
    // raylib's window creation and event pump are main-thread-only, and `try server.listen()` blocks forever —
    // so the two swap places relative to the old shell-out design. The desk is no longer a child process, so
    // there is nothing to spawn and nothing to wait on: runApp RETURNING (user closed the window) is the
    // shutdown signal that DeskWatch used to derive from a child exit.
    //
    // The job object still goes up FIRST, and still matters: workers, neuron, and the browser host are all
    // spawned from this process, and a kill-on-job-close job is the only thing that reaps them when we are
    // hard-killed (Task Manager) and no defer or watcher ever runs.
    ownProcessTree(init.environ_map);
    var st = ServerThread{ .server = &server, .port = port };
    const server_thread = std.Thread.spawn(.{}, ServerThread.run, .{&st}) catch |e| {
        // No server thread = no backend for the GUI to talk to. Fall back to the blocking listen rather than
        // opening a window onto nothing.
        log.err("could not start the HTTP thread ({t}) — running server-only on this thread instead", .{e});
        return server.listen();
    };
    server_thread.detach();
    // Give httpz a moment to actually bind before the GUI's 1Hz liveness probe starts. The desk handles an
    // offline server fine (it just renders disconnected and retries), so this is cosmetic — it only avoids a
    // "server offline" flash on every launch. Bounded and best-effort: never block the window on the backend.
    awaitServer(gpa, io, port, 3000);

    desk.runApp(paths.data) catch |e| {
        // NO WINDOW is not a reason to take the server down with it — the server is the useful half, and
        // the web UI is right there. Degrade instead of exiting silently (see serveWithoutDesk).
        if (e == error.WindowUnavailable) serveWithoutDesk(io, port, paths.data);
        log.err("desktop GUI exited with an error: {t}", .{e});
    };

    // The window IS the app's lifetime (same contract the old DeskWatch enforced across the process boundary).
    log.info("desktop window closed — shutting down. Use --server-only to run the server without a GUI.", .{});
    server.stop(); // wake the listen thread so it unwinds instead of holding the port
    // Then exit outright rather than returning: main's `defer server.deinit()` would race the listen thread
    // that is still unwinding, and the job object (Windows) reaps the descendants on process exit anyway.
    threadSleepMs(io, 150);
    std.process.exit(0);
}

/// The desktop could not open a window (no OpenGL 3.3: a VM, an RDP session, a missing or stale graphics
/// driver). The SERVER is already listening on its own thread and is the half that still works, so degrade
/// to server-only rather than tearing it down — and, above all, TELL the user. This is the one path where
/// no log line can reach them: a double-clicked veil relaunched itself with CREATE_NO_WINDOW, so there is
/// no console, and now there is no window either. On Windows that leaves exactly one visible channel.
/// Never returns: the server thread owns the port, this one just has to stay alive.
fn serveWithoutDesk(io: std.Io, port: u16, data_dir: []const u8) noreturn {
    log.err("the desktop could not open a window — no OpenGL 3.3 (a virtual machine, a Remote Desktop session, or a missing/stale graphics driver).", .{});
    log.info("the server is still running: open http://127.0.0.1:{d} in a browser. Use --server-only to skip the desktop next time.", .{port});
    // Leave the reason on disk too, beside the one the desk's own exit path writes.
    var pb: [512]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/desk-exit-reason.txt", .{data_dir})) |p| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "the desktop could not open a window (no OpenGL 3.3) - running server-only; use the web UI" }) catch {};
    } else |_| {}
    if (builtin.os.tag == .windows) {
        var mb: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&mb, "The desktop window could not open on this machine.\n\n" ++
            "That usually means OpenGL 3.3 is unavailable - a virtual machine, a Remote Desktop session, " ++
            "or a missing/stale graphics driver.\n\n" ++
            "The veil server IS running. Open this in your browser:\n\n" ++
            "    http://127.0.0.1:{d}\n\n" ++
            "Closing this message leaves the server running. Run \"veil --server-only\" to skip the desktop next time.", .{port}) catch
            "The desktop window could not open (no OpenGL 3.3). The veil server is running - open http://127.0.0.1:8787 in your browser.";
        _ = winapp.MessageBoxA(null, msg, "the veil", 0x0000_0030 | 0x0001_0000); // MB_ICONWARNING | MB_SETFOREGROUND
    }
    while (true) threadSleepMs(io, 60_000);
}

/// Runs httpz's blocking accept loop OFF the main thread so raylib can own main. Everything it touches
/// (`server`) lives on main's stack for the life of the process — main never returns normally in app mode, it
/// exits via std.process.exit once the window closes.
const ServerThread = struct {
    server: *httpz.Server(*App),
    port: u16,

    fn run(self: *ServerThread) void {
        self.server.listen() catch |e| {
            // Almost always "port already in use" — another veil is up. Say so loudly: the GUI will come up
            // regardless and would otherwise just look mysteriously disconnected.
            log.err("HTTP server failed to listen on port {d}: {t} — the desktop window will open but has NO backend (is another veil already running?)", .{ self.port, e });
        };
    }
};

/// Poll the loopback health endpoint until the server answers or `budget_ms` elapses. Best-effort and
/// deliberately short: a slow bind must delay the window, never prevent it.
fn awaitServer(gpa: std.mem.Allocator, io: std.Io, port: u16, budget_ms: u64) void {
    const httpc = @import("worker/httpc.zig");
    var waited: u64 = 0;
    while (waited < budget_ms) {
        switch (httpc.request(io, gpa, .{ .method = "GET", .port = port, .path = "/api/v1/health", .timeout_s = 2, .cap = 4 << 10 })) {
            .ok => |resp| {
                const up = resp.status == 200;
                if (resp.body.len > 0) gpa.free(resp.body);
                if (up) return;
            },
            else => {},
        }
        threadSleepMs(io, 50);
        waited += 50;
    }
    log.warn("HTTP server was not answering on port {d} after {d}ms — opening the window anyway; it will connect when the server comes up", .{ port, budget_ms });
}

const DEFAULT_ADMIN_EMAIL = "admin@neuron-loops.local";

/// Ensure a valid admin API key sits at <data>/.desktop_key so the desktop auto-connects. Reuses the
/// existing key if it still verifies; otherwise logs in as the admin, mints one, and writes it. Best-effort.
/// Save a generated admin password beside the data it protects. Logged once is not good enough: on a
/// double-click launch there is no console at all, and the person who needs it is the one who did not
/// set NL_ADMIN_PASSWORD in the first place.
fn writeAdminPassword(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, pw: []const u8) void {
    _ = gpa;
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/admin-password.txt", .{data_dir}) catch return;
    var body: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "admin password: {s}\n\n" ++
        "Generated because NL_ADMIN_PASSWORD was not set and this server is reachable\n" ++
        "on the network. Set NL_ADMIN_PASSWORD to choose your own.\n", .{pw}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// Read back a password this server generated earlier, so a restart does not mint a new one and
/// invalidate what the user wrote down. Returns null when the file is absent or does not look like a
/// password line we wrote.
fn readAdminPassword(io: std.Io, data_dir: []const u8, out: *[48]u8) ?[]const u8 {
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/admin-password.txt", .{data_dir}) catch return null;
    var buf: [512]u8 = undefined;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(buf.len)) catch return null;
    defer std.heap.page_allocator.free(data);
    const n = data.len;
    @memcpy(buf[0..n], data);
    const tag = "admin password: ";
    const at = std.mem.indexOf(u8, buf[0..n], tag) orelse return null;
    var rest = buf[at + tag.len .. n];
    if (std.mem.indexOfAny(u8, rest, "\r\n")) |e| rest = rest[0..e];
    const pw = std.mem.trim(u8, rest, " \t");
    if (pw.len < 8 or pw.len > out.len) return null;
    @memcpy(out[0..pw.len], pw);
    return out[0..pw.len];
}

/// MIGRATE the pre-split durable memory store into the admin's per-user one.
///
/// Splitting {data}/.veil-desk/memories.jsonl per uid was right — it backs get_credential, and one
/// global file meant every account would read every other account's stored secrets the moment chat
/// opened up. But the existing file was left where it was, so an upgraded install came up with an
/// EMPTY store: the injection path had a read-fallback for uid 1, and get_credential — which reads
/// ctx.durable_path directly — did not. Credentials that were plainly there stopped being findable.
///
/// A read-fallback alone would have been a trap rather than a fix. Writes go only to the per-user
/// path, so the first stored memory would create that file, the fallback would stop being consulted,
/// and every legacy credential would vanish with nothing to say why. Copying once removes the
/// ambiguity: afterwards there is one file, and it is the one everything reads and writes.
///
/// The original is left in place, deliberately. It costs a few KB and it is the only copy of
/// credentials the user may have no other record of — this is not the moment to be tidy.
fn migrateLegacyMemories(gpa: std.mem.Allocator, io: std.Io, data: []const u8, admin_uid: u64) void {
    var lb: [700]u8 = undefined;
    var nb2: [700]u8 = undefined;
    const legacy = std.fmt.bufPrint(&lb, "{s}/.veil-desk/memories.jsonl", .{data}) catch return;
    const mine = std.fmt.bufPrint(&nb2, "{s}/u{d}/.veil-desk/memories.jsonl", .{ data, admin_uid }) catch return;

    // Already migrated (or the user has their own store) — never overwrite it.
    if (std.Io.Dir.cwd().statFile(io, mine, .{})) |_| return else |_| {}
    const body = std.Io.Dir.cwd().readFileAlloc(io, legacy, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(body);
    if (body.len == 0) return;

    var db: [700]u8 = undefined;
    const dir = std.fmt.bufPrint(&db, "{s}/u{d}/.veil-desk", .{ data, admin_uid }) catch return;
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = mine, .data = body }) catch |e| {
        log.warn("could not migrate the durable memory store to u{d} ({t}) — get_credential may find nothing", .{ admin_uid, e });
        return;
    };
    log.info("migrated the durable memory store into u{d}/.veil-desk/ ({d} bytes); the original is kept as a backup", .{ admin_uid, body.len });
}

fn preloadDesktopKey(gpa: std.mem.Allocator, io: std.Io, auth: *Auth, keys: *@import("auth/api_keys.zig").ApiKeys, environ: *std.process.Environ.Map, data: []const u8, admin_pw: ?[]const u8) void {
    // Written unconditionally so the desktop and the CLI connect whether the server was auto-started or
    // launched later. It is a same-user local file; the port being open to the LAN does not change that.
    //
    // `admin_pw` is the password that was ACTUALLY seeded, passed in rather than re-read from the
    // environment. It used to assume "changeme", which quietly stopped being true the moment an unset
    // password started being generated: the login below failed, the key was never written, and the desk
    // and CLI lost their local auth with nothing in the log to say why.
    const path = std.fmt.allocPrint(gpa, "{s}/.desktop_key", .{data}) catch return;
    defer gpa.free(path);
    // reuse an existing valid key
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256))) |old| {
        defer gpa.free(old);
        if (keys.verify(std.mem.trim(u8, old, " \r\n\t")) != null) return;
    } else |_| {}
    const email = environ.get("NL_ADMIN_EMAIL") orelse DEFAULT_ADMIN_EMAIL;
    const pw = admin_pw orelse "changeme"; // null = nothing was seeded, so the shipped default stands
    const tok = auth.login(email, pw) catch |e| {
        log.warn("veil-desk: could not mint the local API key ({t}) — the desk and `veil <verb>` will ask for auth", .{e});
        return;
    };
    defer gpa.free(tok);
    const u = auth.whoami(tok) orelse return;
    const key = keys.create(u.id, "veil-desk") catch return;
    defer gpa.free(key);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = key }) catch return;
    log.info("veil-desk: preloaded an admin API key at <data>/.desktop_key (localhost)", .{});
}

// GONE, and deliberately: launchDesktop / DeskWatch / watchDesk. The desk used to be a SEPARATE
// veil-desk.exe that this process spawned, found by probing two layouts (bundle-adjacent, then
// desk/zig-out/bin), with a watcher thread blocking on the child handle to turn "user closed the desk" into a
// server shutdown. The GUI is now compiled in and runs on the main thread, so there is no child to find, no
// spawn to fail, and no handle to wait on — runApp returning IS the exit signal (see app mode in main).
// NL_NO_DESKTOP is likewise retired; `--server-only` is the one way to ask for a server without a window.

fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true, .service = "veil", .version = VERSION }, .{});
}

/// GET /api/v1/themes → {ok:true, themes:[{id,name,dark,mono_ui,builtin,colors:{...}}]}. PUBLIC (no auth):
/// the palette is not a secret and the web app paints its login screen from it, exactly like styles.css.
/// Reads the live registry's theme workspace; if the plugin layer isn't wired (should not happen — main
/// always loads it), falls back to the three compiled-in builtins so a client always gets a usable set.
fn themesList(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(res.arena, "{\"ok\":true,\"themes\":") catch return http.serverErr(res, "oom");
    if (plugins.current(&app.plugs)) |reg| {
        plug_theme.writeJson(&reg.themes, res.arena, &out) catch return http.serverErr(res, "oom");
    } else {
        var set: plug_theme.ThemeSet = .{};
        plug_theme.loadWorkspace(app.gpa, app.io, app.data, &set);
        plug_theme.writeJson(&set, res.arena, &out) catch return http.serverErr(res, "oom");
    }
    out.append(res.arena, '}') catch return http.serverErr(res, "oom");
    res.content_type = .JSON;
    res.body = out.items;
}

/// GET /api/v1/plugins → {ok:true, plugins:[...]}. AUTHED: it names the extensions that hook a user's
/// turns (and any that failed to load, with the error), so it is operational detail behind a login.
fn pluginsList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    const reg = plugins.current(&app.plugs) orelse {
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"plugins\":[]}";
        return;
    };
    const arr = reg.listJson(app.gpa);
    defer app.gpa.free(arr);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"plugins\":{s}}}", .{arr});
}

/// POST /api/v1/plugins/reload → rescan {data}/plugins + {data}/themes and atomic-swap the live registry.
/// ADMIN-ONLY. The previous registry is intentionally leaked (a turn may still hold it) — reload is rare,
/// the leak is bounded, and this is the same never-free-in-place discipline recipes use.
fn pluginsReload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const environ = app.sup.parent_env;
    const new_reg = plugins.loadAll(app.gpa, app.io, environ, app.data, .{});
    plugins.swap(&app.plugs, new_reg);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"plugins\":{d},\"themes\":{d}}}", .{ new_reg.count(), new_reg.themes.count });
}

/// GET /api/v1/health/deps → {ok:true, deps:[{name,present,version,hint}, …]} — one row per binary the
/// toolbelt spawns (python, node, npm, curl, git, browser). The desk and the AI read this to know what the
/// environment is MISSING and exactly how to fix it, instead of decoding a flat "X failed to run" only after
/// a tool has already dead-ended. The array is nested under `deps` (not returned bare) so the reply carries
/// the same `ok` envelope every other GET here does — health/, fleet, models/local all wrap.
///
/// AUTHED (requireUser), matching /models/local, which is the closest precedent: both inspect what THIS host
/// can actually do. Dep presence is not a secret, but the version strings are operational detail (a version
/// can name an exploitable build), so it stays behind a login rather than sitting pre-login like plain
/// /health. It is deliberately NOT admin-only: every authenticated user's tools spawn these binaries, so any
/// of them legitimately needs to know why one is absent — and a tool only ever runs for an authenticated
/// user anyway, so the gate never impedes the actual use case.
///
/// SIDE-EFFECT-FREE: probeAll resolves binaries on PATH + best-effort reads `--version`. It NEVER installs,
/// downloads, or mutates anything. Behind a 15s TTL cache (below) so the ~12 short-lived probe subprocesses
/// run at most once per 15s regardless of poll rate — dependency presence changes only on an install/remove,
/// so the cache is effectively always fresh, and it also caps the process churn an authed tight-loop could
/// otherwise cause. The env comes from the supervisor's captured parent environ (same source chat/tools.zig
/// probes). Cache strings live in g_deps_arena, reset whole on each refresh; every access is under g_deps_mu.
var g_deps_mu: std.Io.Mutex = .init;
var g_deps_arena: ?std.heap.ArenaAllocator = null;
var g_deps_json: []const u8 = "";
var g_deps_at: i64 = 0;
const DEPS_TTL_S: i64 = 15;

fn healthDeps(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    const environ = app.sup.parent_env orelse return http.serverErr(res, "server env unavailable");
    const now = std.Io.Timestamp.now(app.io, .real).toSeconds();

    g_deps_mu.lockUncancelable(app.io);
    defer g_deps_mu.unlock(app.io);
    if (g_deps_json.len == 0 or now - g_deps_at >= DEPS_TTL_S) {
        // Stale or first call: reset the cache arena (frees the previous body + all its Dep strings in one
        // shot), re-probe into it, and render. On OOM leave the cache empty and 500 rather than serve junk.
        if (g_deps_arena) |*a| _ = a.reset(.free_all) else g_deps_arena = std.heap.ArenaAllocator.init(app.gpa);
        const ca = g_deps_arena.?.allocator();
        const probed = deps.probeAll(ca, app.io, environ);
        g_deps_json = std.json.Stringify.valueAlloc(ca, .{ .ok = true, .deps = probed }, .{}) catch {
            g_deps_json = "";
            return http.serverErr(res, "could not render dependency status");
        };
        g_deps_at = now;
    }
    // Copy out under the lock so a concurrent refresh can never reset the arena from under this response.
    res.content_type = .JSON;
    res.body = res.arena.dupe(u8, g_deps_json) catch return http.serverErr(res, "oom");
}

// ---- the BUILT-IN model routes -------------------------------------------------------------------

/// modelpull's store-change hook: re-point the engine at whatever the store now elects. Runs on the
/// pull/import thread; repoint is thread-safe. Only referenced from the comptime HAS_BUILTIN branch
/// of boot, so a lean build never analyzes the llamaeng call.
fn builtinStoreChanged() void {
    if (comptime HAS_BUILTIN) llamaeng.repoint(builtin_state.modelPath());
}

/// modelpull's pre-swap hook: the engine drops its file mapping (waiting out any in-flight
/// generation) so the store can replace/remove the weights under Windows' open-file locks.
fn builtinBeforeSwap() void {
    if (comptime HAS_BUILTIN) llamaeng.unload();
}

/// GET /api/v1/models/builtin → the one snapshot the desk row, the web settings and `veil model
/// status` all render: compiled?, endpoint port, weights store, engine state, transfer progress.
/// A transfer in flight is the headline (it is what the user is waiting on); otherwise the engine
/// state is (absent/cold/ready/failed).
fn builtinStatus(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    const ps = modelpull.status();
    const inf: builtin_state.Info = if (comptime HAS_BUILTIN) llamaeng.info() else .{};
    const transferring = switch (ps.state) {
        .resolving, .downloading, .verifying, .importing => true,
        else => false,
    };
    const headline: []const u8 = if (transferring or ps.state == .failed) @tagName(ps.state) else @tagName(inf.state);
    const pct: u64 = if (ps.bytes_total > 0) @min(ps.bytes_done * 100 / ps.bytes_total, 100) else 0;
    const cs = modelpull.checkStatus();
    try res.json(.{
        .ok = true,
        .compiled = HAS_BUILTIN,
        .state = headline,
        .model = builtin_state.MODEL_ID,
        .repo = builtin_state.HF_REPO,
        .port = builtin_state.port(),
        .file = ps.file,
        .path = builtin_state.modelPath() orelse "",
        .bytes_total = ps.bytes_total,
        .bytes_done = ps.bytes_done,
        .pct = pct,
        .arch = inf.archName(),
        .params_b = inf.params_b,
        .ctx = inf.ctx_serving,
        .err = if (ps.state == .failed) ps.err else inf.errMsg(),
        .synced_dir_warning = builtin_state.syncedDirWarning(),
        // the update lane: what the repo currently publishes vs what this store serves
        .update_state = @tagName(cs.state),
        .update_file = cs.file,
        .update_mb = cs.mb,
        .checked_s = cs.checked_s,
        .installed_sha12 = cs.inst_sha12,
        .installed_source = cs.inst_src,
    }, .{});
}

/// POST /api/v1/models/builtin/check → compare the repo's current artifact against the install
/// manifest, on a background thread; the verdict lands in status as update_state. Deliberately
/// USER-INITIATED egress only — this server never phones the repo on its own.
fn builtinCheck(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    modelpull.startCheck() catch |e| {
        res.status = if (e == error.Busy) 409 else 503;
        try res.json(.{ .ok = false, .@"error" = if (e == error.Busy) "a transfer or check is already running" else "the downloader is not ready" }, .{});
        return;
    };
    try res.json(.{ .ok = true, .started = true }, .{});
}

/// POST /api/v1/models/builtin/pull → start the background download from the published repo.
/// 409 while one runs; the client then just polls status.
fn builtinPull(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    modelpull.startPull() catch |e| {
        res.status = if (e == error.Busy) 409 else 503;
        try res.json(.{ .ok = false, .@"error" = if (e == error.Busy) "a pull or import is already running" else "the downloader is not ready" }, .{});
        return;
    };
    try res.json(.{ .ok = true, .started = true }, .{});
}

/// POST /api/v1/models/builtin/cancel → cooperative cancel; the .part stays for a later resume.
fn builtinCancel(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    modelpull.cancel();
    try res.json(.{ .ok = true }, .{});
}

/// POST /api/v1/models/builtin/import {path?} → copy an already-downloaded GGUF into the store on a
/// background thread (path absent = auto-discover the local runtime's verified blob for this model).
fn builtinImport(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    var explicit: ?[]const u8 = null;
    if (req.body()) |b| {
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, b, .{}) catch null;
        if (parsed) |p| if (p.value == .object) if (p.value.object.get("path")) |v| if (v == .string and v.string.len > 0) {
            explicit = v.string;
        };
    }
    modelpull.startImport(explicit) catch |e| {
        res.status = if (e == error.Busy) 409 else 400;
        try res.json(.{ .ok = false, .@"error" = switch (e) {
            error.Busy => "a pull or import is already running",
            error.PathTooLong => "path too long",
            else => "the importer is not ready",
        } }, .{});
        return;
    };
    try res.json(.{ .ok = true, .started = true }, .{});
}

/// DELETE /api/v1/models/builtin → drop the serving weights (refused mid-transfer). The engine
/// re-points to nothing via the same store-change hook the pull uses.
fn builtinDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireUser(app, req, res) orelse return;
    modelpull.remove(app.io) catch |e| {
        res.status = if (e == error.Busy) 409 else 500;
        try res.json(.{ .ok = false, .@"error" = if (e == error.Busy) "a pull or import is running — cancel it first" else "could not remove the weights file" }, .{});
        return;
    };
    try res.json(.{ .ok = true }, .{});
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

/// Compress the embedded assets ONCE, at boot, and mint their entity tags. Per-request compression would
/// redo byte-identical work forever: the bodies are @embedFile'd, so the input provably cannot change while
/// this process runs. Costs ~60 KiB of resident memory and a few ms of startup to take the cold-load
/// payload from ~222 KB to ~63 KB. Nothing here is freed on purpose — it lives as long as the process does.
///
/// Must be called before the router is wired. Best-effort throughout: an asset that fails to compress or to
/// get a tag simply falls back to the old behaviour (full body, no conditional GET), never to a broken one.
fn prepareStatics(gpa: std.mem.Allocator) void {
    var saved: usize = 0;
    for ([_]*StaticAsset{ &static_html, &static_js, &static_css, &static_models }) |a| {
        // The tag folds a hash of the ACTUAL BYTES in beside VERSION rather than using VERSION alone. Both
        // halves earn their place: VERSION keeps tags from two releases visibly distinct, and the content
        // hash means a dev rebuild that edits app.js without bumping VERSION still invalidates every
        // client's copy. VERSION alone would hand back a 304 for a body that had changed.
        const h = std.hash.Wyhash.hash(0, a.body);
        const tag = std.fmt.allocPrint(gpa, "\"{s}-{x}\"", .{ VERSION, h }) catch continue;
        // A DIFFERENT tag for the gzip. An entity tag names a representation, not a URL, so the two
        // encodings of one file must not share one — a shared cache keyed on the tag would otherwise be
        // free to answer an identity request out of a gzipped entry.
        const tag_gz = std.fmt.allocPrint(gpa, "\"{s}-{x}-gz\"", .{ VERSION, h }) catch continue;
        a.etag = tag;
        a.etag_gz = tag_gz;
        if (gzipAlloc(gpa, a.body)) |gz| {
            // Only keep the compressed copy if it actually won. models.json is small enough that gzip's
            // header and footer could in principle outweigh what it saves; shipping it then would cost the
            // client a decompress for nothing.
            if (gz.len < a.body.len) {
                a.gz = gz;
                saved += a.body.len - gz.len;
            } else gpa.free(gz);
        } else |e| log.warn("static assets: gzip failed ({t}) — serving this one uncompressed", .{e});
    }
    if (saved > 0) log.info("static assets: gzipped at boot, {d} KB off every cold load", .{saved / 1024});
}

/// gzip `src` at level 9 into a fresh allocation. Boot-time only — level 9 is the slowest setting and the
/// right one exactly once per process.
fn gzipAlloc(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const flate = std.compress.flate;
    // Both of these are heap, not stack, and deliberately: the match window is 64 KiB and Compress itself
    // is ~224 KiB of lookup and token tables. That is most of a Windows thread's default 1 MiB stack.
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, src.len / 2 + 64);
    errdefer out.deinit();
    // init writes the gzip header straight to `out`, so `out` must outlive `c` — it does, both are locals
    // and c is finished below before either goes away.
    c.* = try flate.Compress.init(&out.writer, window, .gzip, .level_9);
    try c.writer.writeAll(src);
    try c.finish(); // emits the final block + CRC32/length footer; the stream is invalid without it
    return try out.toOwnedSlice();
}

/// Serve one embedded asset with conditional GET and, where the client allows it, gzip.
///
/// The ETag is safe here for a reason worth stating plainly: these bodies are @embedFile'd, fixed at COMPILE
/// time. There is no file on disk for anyone to edit out from under a running server, so a body can only
/// change by way of a new binary — and a new binary hashes differently. A tag minted at boot therefore
/// cannot go stale for as long as it is in use. That fact is what makes the whole approach sound; without
/// it, serving 304s off a tag nobody re-derives per request would be a bug waiting on a deploy.
fn serveStatic(req: *httpz.Request, res: *httpz.Response, a: *const StaticAsset) void {
    // Vary on EVERY response, including the identity body and the 304. Without it an intermediary keys its
    // cache on the URL alone and is entitled to hand a gzipped entry to a client that never asked for one
    // and cannot decode it — a blank page with no clue as to why, and not reproducible from the server.
    res.header("Vary", "Accept-Encoding");
    res.header("Cache-Control", "no-cache, must-revalidate");

    const ae = req.header("accept-encoding") orelse req.header("Accept-Encoding") orelse "";
    const use_gz = a.gz != null and std.mem.indexOf(u8, ae, "gzip") != null;
    const tag = if (use_gz) a.etag_gz else a.etag;

    // Guarded on tag.len, and not as a formality: an empty tag would make the indexOf below match ANY
    // If-None-Match (indexOf of "" is 0), so a failed allocation in prepareStatics would turn into a
    // permanent 304 and a blank app. No tag means no conditional GET at all.
    if (tag.len > 0) {
        res.header("ETag", tag);
        // If-None-Match is a comma-separated list whose members may carry a W/ prefix. A substring test
        // handles both shapes and cannot collide here — every tag carries a 64-bit content hash.
        if (req.header("if-none-match") orelse req.header("If-None-Match")) |inm| {
            if (std.mem.indexOf(u8, inm, tag) != null) {
                res.status = 304;
                res.body = ""; // a 304 carries no body, and notably no Content-Encoding either
                return;
            }
        }
    }
    if (use_gz) {
        res.header("Content-Encoding", "gzip");
        res.body = a.gz.?;
    } else res.body = a.body;
}

fn staticIndex(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    serveStatic(req, res, &static_html);
}
fn staticJs(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    serveStatic(req, res, &static_js);
}
fn staticCss(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    serveStatic(req, res, &static_css);
}
fn staticModels(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    serveStatic(req, res, &static_models);
}

// ---------------------------------------------------------------------------
// PWA — install the web app from whatever domain the user actually connected to.
//
// The manifest is built PER REQUEST from the Host header instead of being another @embedFile: an install
// binds to the ORIGIN that served the manifest, and this server is reached at both `localhost:8787` and
// whatever public name a deploy fronts it with. A baked-in start_url would pin every install to one of
// those and quietly break the other. Every URL field stays RELATIVE — relative resolves against the
// manifest's own URL, so it is right on every origin including a proxy with a path prefix, and it cannot
// mis-resolve the way a hand-built absolute URL can when a header lies. The host only ever reaches the
// human-readable `description`, so a bad Host header costs a cosmetic string, never a broken install.
//
// Icons are inline SVG rather than PNG files: Chromium accepts `sizes:"any"` SVG for installability, and
// keeping them here avoids adding two binaries to web/public (each of which is its own build.zig module).
const PWA_ICON_SVG =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="the veil">
    \\<rect width="512" height="512" rx="112" fill="#8a3ffc"/>
    \\<path d="M128 160l128 208 128-208" fill="none" stroke="#fff" stroke-width="48" stroke-linecap="round" stroke-linejoin="round"/>
    \\</svg>
;
// MASKABLE: full-bleed fill (the OS applies its own mask/rounding) with the mark pulled inside the inner
// 80% safe circle, so a circular or squircle mask can never clip the V.
const PWA_ICON_MASKABLE_SVG =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="the veil">
    \\<rect width="512" height="512" fill="#8a3ffc"/>
    \\<path d="M166 198l90 146 90-146" fill="none" stroke="#fff" stroke-width="42" stroke-linecap="round" stroke-linejoin="round"/>
    \\</svg>
;

/// A Host header is attacker-controlled, and it lands inside a JSON string. Keep only what a hostname can
/// legally contain and bound it; anything else collapses to a neutral label rather than escaping into the
/// document. Returns a slice of `host` (no allocation) or a static fallback.
fn safeHost(host: []const u8) []const u8 {
    if (host.len == 0 or host.len > 128) return "this server";
    for (host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':' or c == '_' or c == '[' or c == ']';
        if (!ok) return "this server";
    }
    return host;
}

fn pwaManifest(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const host = safeHost(req.header("host") orelse "");
    res.header("Content-Type", "application/manifest+json; charset=utf-8");
    // Revalidate every load: the manifest VARIES BY HOST, so a shared cache keyed on the URL alone could
    // otherwise hand a public visitor the copy minted for localhost.
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.header("Vary", "Host");
    res.body = try std.fmt.allocPrint(res.arena,
        \\{{"id":"/","name":"the veil","short_name":"veil",
        \\"description":"A hive mind you talk to — chat, swarms, and scheduled tasks. Installed from {s}.",
        \\"start_url":"/","scope":"/","display":"standalone","display_override":["window-controls-overlay","standalone","minimal-ui"],
        \\"orientation":"any","background_color":"#1a1b26","theme_color":"#1a1b26","categories":["productivity","developer"],
        \\"icons":[{{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}},
        \\{{"src":"/icon-maskable.svg","sizes":"any","type":"image/svg+xml","purpose":"maskable"}}]}}
    , .{host});
}

fn pwaServiceWorker(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    // A worker may only control paths at or below its own URL, so it MUST be served from the root — and the
    // browser re-checks the script on every navigation, so it must never be cached hard.
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.header("Service-Worker-Allowed", "/");
    // NETWORK-FIRST, shell-only. The app is a live view of a local server: caching API responses would
    // serve stale turns, stale auth, and stale event cursors, so /api/ is skipped entirely and only the
    // three shell files are ever stored — enough to open the app offline and have it say the server is
    // unreachable, which is the honest offline state for a client whose whole job is talking to a server.
    // VERSION rides in the cache name, so a new binary orphans the old cache and activate() sweeps it.
    res.body = try std.fmt.allocPrint(res.arena,
        \\const CACHE = 'veil-shell-{s}';
        \\const SHELL = ['/', '/app.js', '/styles.css'];
        \\self.addEventListener('install', (e) => {{
        \\  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()).catch(() => {{}}));
        \\}});
        \\self.addEventListener('activate', (e) => {{
        \\  e.waitUntil(caches.keys()
        \\    .then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
        \\    .then(() => self.clients.claim()).catch(() => {{}}));
        \\}});
        \\self.addEventListener('fetch', (e) => {{
        \\  const req = e.request;
        \\  if (req.method !== 'GET') return;
        \\  const url = new URL(req.url);
        \\  if (url.origin !== self.location.origin) return;
        \\  if (url.pathname.startsWith('/api/')) return;   // live server state — never cached
        \\  e.respondWith(fetch(req).then((r) => {{
        \\    if (r && r.ok && SHELL.includes(url.pathname)) {{
        \\      const copy = r.clone();
        \\      caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {{}});
        \\    }}
        \\    return r;
        \\  }}).catch(() => caches.match(req).then((hit) => hit || caches.match('/'))));
        \\}});
    , .{VERSION});
}

fn pwaIcon(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Content-Type", "image/svg+xml; charset=utf-8");
    res.header("Cache-Control", "public, max-age=86400");
    res.body = PWA_ICON_SVG;
}

fn pwaIconMaskable(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Content-Type", "image/svg+xml; charset=utf-8");
    res.header("Cache-Control", "public, max-age=86400");
    res.body = PWA_ICON_MASKABLE_SVG;
}

test "safeHost: passes real hostnames, neutralizes anything that could break out of the JSON string" {
    try std.testing.expectEqualStrings("localhost:8787", safeHost("localhost:8787"));
    try std.testing.expectEqualStrings("veil.example.com", safeHost("veil.example.com"));
    try std.testing.expectEqualStrings("[::1]:8787", safeHost("[::1]:8787"));
    // a quote/backslash/newline in Host must never reach the manifest body
    try std.testing.expectEqualStrings("this server", safeHost("evil\",\"name\":\"pwned"));
    try std.testing.expectEqualStrings("this server", safeHost("a\\b"));
    try std.testing.expectEqualStrings("this server", safeHost(""));
}

// ---------------------------------------------------------------------------
// ROUTER AUDIT. Each handler module's own tests prove that handler REFUSES an unauthorised caller;
// none of them prove the router points at the handler anyone thinks it does. A route wired to the
// wrong function — an admin path aimed at a merely-authenticated handler, a new endpoint added
// without a gate — is invisible to every one of those sweeps, and it is the one mistake that
// silently undoes all of them.
//
// So this reads the route table as text and re-derives, for every route, whether its handler
// actually gates: directly, or through ONE local helper (sched.zig wraps requireUser in `gate()`,
// which a naive body scan reads as ungated).
// ---------------------------------------------------------------------------

const MAIN_SRC = @embedFile("main.zig");

const ROUTE_MODS = [_]struct { alias: []const u8, src: []const u8 }{
    .{ .alias = "auth_api", .src = @embedFile("auth/auth_api.zig") },
    .{ .alias = "deploy_service", .src = @embedFile("worker/deploy/service.zig") },
    .{ .alias = "tail_fanout", .src = @embedFile("worker/control/fanout.zig") },
    .{ .alias = "control_writer", .src = @embedFile("worker/control/writer.zig") },
    .{ .alias = "chat_tools", .src = @embedFile("worker/chat/tools.zig") },
    .{ .alias = "chat_service", .src = @embedFile("worker/chat/service.zig") },
    .{ .alias = "sched", .src = @embedFile("worker/sched.zig") },
    .{ .alias = "metrics", .src = @embedFile("worker/metrics.zig") },
    .{ .alias = "admin_service", .src = @embedFile("admin/admin_service.zig") },
    .{ .alias = "billing_seam", .src = @embedFile("plan/billing_seam.zig") },
    .{ .alias = "keys_api", .src = @embedFile("config/keys_api.zig") },
    .{ .alias = "local_models", .src = @embedFile("config/local_models.zig") },
    .{ .alias = "cf_oauth", .src = @embedFile("config/cf_oauth.zig") },
    .{ .alias = "browser_ext_api", .src = @embedFile("worker/browser/ext_api.zig") },
};

/// Routes that are deliberately reachable without a session. Each needs a REASON, because the only
/// thing separating this list from a hole is that a human wrote down why.
const PUBLIC_ROUTES = [_]struct { path: []const u8, why: []const u8 }{
    .{ .path = "/api/v1/health", .why = "liveness probe; reports version only" },
    .{ .path = "/api/v1/health/deps", .why = "dependency probe for the installer" },
    .{ .path = "/api/v1/fleet", .why = "dev.ps1 and `veil doctor` probe this before a key exists" },
    .{ .path = "/api/v1/themes", .why = "documented PUBLIC in the CLI: themes are presentation data" },
    .{ .path = "/api/v1/auth/register", .why = "you cannot hold a session before registering" },
    .{ .path = "/api/v1/auth/login", .why = "ditto; throttled by login_guard instead" },
    .{ .path = "/api/v1/auth/logout", .why = "clearing a cookie must work even with a dead session" },
    .{ .path = "/api/v1/auth/me", .why = "answers authed:false to a stranger — that IS its job" },
    .{ .path = "/api/v1/oauth/cloudflare/callback", .why = "the IdP redirects the browser here" },
    .{ .path = "/api/v1/browser/ext/hello", .why = "the extension's discovery probe: it must answer before any credential exists. Reports the app name and protocol version, nothing else" },
    .{ .path = "/api/v1/browser/ext/pair", .why = "mints the extension's relay token; gated on the SOCKET being loopback instead of on a session, because the browser offering itself has no account" },
};

/// `ext` is the browser extension's own credential (the loopback-issued relay token, checked by
/// ext_api.requireExt) rather than a user session. It is a real gate — it just is not this app's user gate,
/// and calling it `.none` would either fail the audit or, worse, push these routes onto the public list.
const Gate = enum { admin, user, ext, none, missing };

/// The body of `fn name(` / `pub fn name(` in `src`, up to the next top-level fn.
fn fnBodyIn(src: []const u8, name: []const u8) ?[]const u8 {
    var buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "fn {s}(", .{name}) catch return null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |at| {
        // must start a line, optionally after "pub "
        const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        const prefix = src[line_start..at];
        if (prefix.len == 0 or std.mem.eql(u8, prefix, "pub ")) {
            const rest = src[at..];
            const end = std.mem.indexOfPos(u8, rest, 1, "\nfn ") orelse
                std.mem.indexOfPos(u8, rest, 1, "\npub fn ") orelse rest.len;
            return rest[0..end];
        }
        i = at + 1;
    }
    return null;
}

fn gateOfFn(src: []const u8, name: []const u8, depth: u8) Gate {
    const body = fnBodyIn(src, name) orelse return .missing;
    if (std.mem.indexOf(u8, body, "requireAdmin") != null) return .admin;
    if (std.mem.indexOf(u8, body, "requireUser") != null) return .user;
    if (std.mem.indexOf(u8, body, "requireExt") != null) return .ext;
    if (depth == 0) {
        // one hop: a local helper taking (app, req, res) — sched.zig's `gate()` is the real case
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, body, i, "(app, req, res)")) |at| {
            i = at + 1;
            const before = body[0..at];
            var s = before.len;
            while (s > 0) {
                const c = before[s - 1];
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') s -= 1 else break;
            }
            const callee = before[s..];
            if (callee.len == 0) continue;
            const g = gateOfFn(src, callee, depth + 1);
            if (g == .admin or g == .user) return g;
        }
    }
    return .none;
}

test "the router: every admin path is admin-gated, and nothing else is open by accident" {
    var checked: usize = 0;
    var gated: usize = 0;
    var it = std.mem.splitScalar(u8, MAIN_SRC, '\n');
    while (it.next()) |line| {
        const rp = std.mem.indexOf(u8, line, "router.") orelse continue;
        const q1 = std.mem.indexOfScalarPos(u8, line, rp, '"') orelse continue;
        const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse continue;
        const path = line[q1 + 1 .. q2];
        const after = line[q2 + 1 ..];
        const comma = std.mem.indexOfScalar(u8, after, ',') orelse continue;
        var handler = std.mem.trim(u8, after[comma + 1 ..], " ,");
        if (std.mem.indexOfScalar(u8, handler, ',')) |c| handler = handler[0..c];
        if (handler.len == 0) continue;
        checked += 1;

        // resolve handler -> (source, fn name)
        var src: []const u8 = MAIN_SRC;
        var fname = handler;
        if (std.mem.indexOfScalar(u8, handler, '.')) |dot| {
            const alias = handler[0..dot];
            fname = handler[dot + 1 ..];
            var found = false;
            for (ROUTE_MODS) |m| {
                if (std.mem.eql(u8, m.alias, alias)) {
                    src = m.src;
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("\nroute {s} -> {s}: module alias '{s}' is not in ROUTE_MODS (add its @embedFile)\n", .{ path, handler, alias });
                return error.UnknownRouteModule;
            }
        }
        const g = gateOfFn(src, fname, 0);
        if (g == .missing) {
            std.debug.print("\nroute {s}: handler '{s}' not found in its module\n", .{ path, handler });
            return error.HandlerNotFound;
        }
        if (g != .none) gated += 1;

        // ADMIN PATHS: nothing less than requireAdmin will do.
        if (std.mem.startsWith(u8, path, "/api/v1/admin")) {
            if (g != .admin) {
                std.debug.print("\nADMIN route {s} -> {s} is only '{t}' — it must call requireAdmin\n", .{ path, handler, g });
                return error.AdminRouteNotAdminGated;
            }
            continue;
        }
        // EVERY OTHER API ROUTE: gated, unless it is on the public list with a stated reason.
        if (std.mem.startsWith(u8, path, "/api/v1/") and g == .none) {
            var allowed = false;
            for (PUBLIC_ROUTES) |p| {
                if (std.mem.eql(u8, p.path, path)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) {
                std.debug.print("\nroute {s} -> {s} has NO auth gate and is not in PUBLIC_ROUTES\n", .{ path, handler });
                return error.UngatedRoute;
            }
        }
    }
    // The table is big; if this ever collapses, the loop above stopped parsing rather than passing.
    try std.testing.expect(checked >= 70);
    try std.testing.expect(gated >= 60);
}

test "the public list stays honest: every entry is a real, still-ungated route" {
    // A path that gains a gate, or disappears, must leave this list — otherwise the list slowly
    // becomes a place where exceptions go to be forgotten.
    for (PUBLIC_ROUTES) |p| {
        try std.testing.expect(p.why.len > 20); // a reason, not a shrug
        var found = false;
        var it = std.mem.splitScalar(u8, MAIN_SRC, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "router.") == null) continue;
            var qb: [128]u8 = undefined;
            const quoted = std.fmt.bufPrint(&qb, "\"{s}\"", .{p.path}) catch continue;
            if (std.mem.indexOf(u8, line, quoted) != null) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\nPUBLIC_ROUTES lists {s}, which no route registers any more\n", .{p.path});
            return error.StalePublicRoute;
        }
    }
}

test "the homepage only references assets the router actually serves" {
    // index.html's own comment records the bug this prevents: "/icon.png has no route on the server,
    // so a linked icon 404s on every load". Two things that must agree — the URLs baked into the
    // page and the route table below — with nothing but attention holding them together. Add a
    // reference without a route (or rename a route and miss the page) and the build stays green
    // while every visitor silently 404s on an asset.
    var refs: usize = 0;
    for ([_][]const u8{ "href=\"", "src=\"" }) |attr| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, ASSET_HTML, i, attr)) |at| {
            const vs = at + attr.len;
            const ve = vs + (std.mem.indexOfScalarPos(u8, ASSET_HTML, vs, '"') orelse break) - vs;
            const url = ASSET_HTML[vs..ve];
            i = ve;
            // Same-origin absolute paths only: data: URIs and anything external are not ours to serve.
            if (url.len < 2 or url[0] != '/') continue;
            refs += 1;

            var route_buf: [128]u8 = undefined;
            if (url.len + 16 > route_buf.len) return error.UrlTooLongForAudit;
            // The needle is SPLIT on purpose. The router audit above scans this same file's source
            // for any line containing `router.` and reads it as a route declaration — so writing
            // this contiguously makes THIS line look like a route named "{s}" and fails that test.
            // Two source-reading audits living in one file will read each other; keep needles apart.
            const needle = try std.fmt.bufPrint(&route_buf, "router" ++ ".get(\"{s}\"", .{url});
            if (std.mem.indexOf(u8, MAIN_SRC, needle) == null) {
                std.debug.print("\nindex.html references '{s}' but no route serves it — every load 404s on it\n", .{url});
                return error.HomepageAssetHasNoRoute;
            }
        }
    }
    // Not vacuous: the page really does carry same-origin references, so the loop above did work.
    // If a rewrite ever inlines everything, this floor fails loudly rather than passing on zero.
    try std.testing.expect(refs >= 4);
}
