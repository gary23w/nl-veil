//! cli/exec_tool.zig — the SHARED client-side tool executor. `veil exec-tool <name>` reads a tool's arguments
//! JSON from stdin, runs it through the server's own tools.execute (so there is ONE implementation of every
//! tool), and prints the result to stdout. It executes in the invoker's working directory, so a client that
//! delegates a server tool_request runs the tool on the USER's machine — the CLI calls runTool in-process, the
//! desk (a separate package) spawns this subcommand. No tool is reimplemented per client.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const tools = @import("../worker/tools.zig");
const osc = @import("../worker/oscillation.zig");
const cync = @import("../worker/chat/sync.zig");
const mcp_client = @import("../worker/mcp/client.zig");

const NEURON_EXE = if (builtin.os.tag == .windows) "neuron.exe" else "neuron";

/// Run one tool with a client-side context rooted at `workdir` (file/shell/code act there). Returns the
/// gpa-owned result string tools.execute produces (always a string, even on error, so it feeds back cleanly).
pub fn runTool(ctx: *cli.Ctx, workdir: []const u8, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ ctx.home, NEURON_EXE }) catch "";
    var db: [700]u8 = undefined;
    const mem_db = std.fmt.bufPrint(&db, "{s}/.veil-client-mem.sqlite", .{ctx.data}) catch "";
    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var tctx = tools.ToolCtx{
        .gpa = gpa,
        .io = ctx.io,
        .environ = ctx.environ,
        .run_dir = workdir,
        .workdir = workdir,
        .scope = "client",
        .mind = "client",
        .round = 0,
        .mem = osc.Mem.init(gpa, ctx.io, neuron_bin, mem_db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
        .vcs_enabled = false,
        // CLIENT privilege: this executor runs on the user's own machine at the user's own request — read-only
        // tools may take absolute/~ paths, and stage_file may copy outside files into the workdir. Swarm minds
        // never get this (their ToolCtx builders don't set it).
        .roam = true,
    };
    return tools.execute(&tctx, name, args_json);
}

/// Single-process exercise of the Feature 2 browser tools through tools.execute (dispatch + NL_BROWSER_DRIVER
/// gate + the process-global session manager): browser_navigate → browser_read → browser_close in sequence, so
/// the persistent session is proven to carry across separate tool calls (an exec-tool one-shot can't). Requires
/// NL_BROWSER_DRIVER=1 in the process env. Rooted at a temp run_dir under `data` (the manager keys sessions by
/// run_dir; its .browser-profile lives there).
pub fn browserFlowSmoke(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, home: []const u8, data: []const u8, url: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ home, NEURON_EXE }) catch "";
    const run_dir = std.fmt.allocPrint(gpa, "{s}/browser-flow-smoke", .{data}) catch return;
    defer gpa.free(run_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/.flow-mem.sqlite", .{run_dir}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .run_dir = run_dir,
        .workdir = run_dir,
        .scope = "flowsmoke",
        .mind = "flowsmoke",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
    };

    const nav_args = std.json.Stringify.valueAlloc(gpa, .{ .url = url }, .{}) catch return;
    defer gpa.free(nav_args);
    inline for (.{ .{ "browser_navigate", nav_args }, .{ "browser_read", "{}" }, .{ "browser_close", "{}" } }) |step| {
        const r = tools.execute(&ctx, step[0], step[1]);
        defer if (r.len > 0) gpa.free(r);
        w.print("--- {s} ---\n{s}\n", .{ step[0], clip(r, 1200) }) catch {};
        w.flush() catch {};
    }
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

/// The FULL RSI-invents-a-browser-tool path (Feature 2, task 3): register a browser-driven tool with make_tool
/// (persisted to the swarm tool registry), then call it — its Python body drives the browser via the injected
/// browser() helper → the loopback broker → the shared session. Proves invention + registration + the bridge,
/// end to end, keyed by run_dir. Requires NL_BROWSER_DRIVER=1 and neuron.exe under {home}/bin.
pub fn browserInventSmoke(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, home: []const u8, data: []const u8, url: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ home, NEURON_EXE }) catch "";
    const run_dir = std.fmt.allocPrint(gpa, "{s}/browser-invent-smoke", .{data}) catch return;
    defer gpa.free(run_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{run_dir}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .run_dir = run_dir,
        .workdir = run_dir,
        .scope = "invent",
        .mind = "invent",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
    };

    // The authored tool's body — composes the browser primitives through the injected browser() helper.
    const body =
        \\u=ARGS.get("url","https://example.com")
        \\browser("navigate",{"url":u})
        \\d=browser("read")
        \\browser("close")
        \\print(_j.dumps({"ok":True,"title":d.get("title"),"count":d.get("count"),"head":(d.get("text") or "")[:80]}))
    ;
    const mk = .{
        .name = "check_page",
        .description = "navigate to a url and report its title + interactive-element count",
        .params = .{ .type = "object", .properties = .{ .url = .{ .type = "string" } }, .required = .{"url"} },
        .body = body,
    };
    const mk_json = std.json.Stringify.valueAlloc(gpa, mk, .{}) catch return;
    defer gpa.free(mk_json);
    const r1 = tools.execute(&ctx, "make_tool", mk_json);
    defer if (r1.len > 0) gpa.free(r1);
    w.print("--- make_tool check_page ---\n{s}\n", .{clip(r1, 400)}) catch {};
    w.flush() catch {};

    const call_args = std.json.Stringify.valueAlloc(gpa, .{ .url = url }, .{}) catch return;
    defer gpa.free(call_args);
    const r2 = tools.execute(&ctx, "check_page", call_args);
    defer if (r2.len > 0) gpa.free(r2);
    w.print("--- invoke check_page (invented, drives browser via broker) ---\n{s}\n", .{clip(r2, 1200)}) catch {};
    w.flush() catch {};
}

/// RSI-invents-an-MCP-tool smoke (round 2, step 4): make_tool registers a tool whose body calls mcp() → the
/// local broker → a discovered MCP server, then invoke it. Proves an invented tool can drive installed MCP
/// servers. Requires NL_MCP=1 and (for the test) APPDATA pointing at a config with a `mock` server.
pub fn mcpInventSmoke(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, home: []const u8, data: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ home, NEURON_EXE }) catch "";
    const run_dir = std.fmt.allocPrint(gpa, "{s}/mcp-invent-smoke", .{data}) catch return;
    defer gpa.free(run_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{run_dir}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .run_dir = run_dir,
        .workdir = run_dir,
        .scope = "mcpinv",
        .mind = "mcpinv",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
    };
    const body =
        \\r=mcp("mock","echo",{"text":ARGS.get("text","hi from an invented tool")})
        \\print(_j.dumps({"ok":True,"echo":r}))
    ;
    const mk = .{
        .name = "call_mock",
        .description = "call the local 'mock' MCP server's echo tool",
        .params = .{ .type = "object", .properties = .{ .text = .{ .type = "string" } } },
        .body = body,
    };
    const mk_json = std.json.Stringify.valueAlloc(gpa, mk, .{}) catch return;
    defer gpa.free(mk_json);
    const r1 = tools.execute(&ctx, "make_tool", mk_json);
    defer if (r1.len > 0) gpa.free(r1);
    w.print("--- make_tool call_mock ---\n{s}\n", .{clip(r1, 300)}) catch {};
    w.flush() catch {};

    const r2 = tools.execute(&ctx, "call_mock", "{\"text\":\"round-two works\"}");
    defer if (r2.len > 0) gpa.free(r2);
    w.print("--- invoke call_mock (invented → mcp() → local MCP server) ---\n{s}\n", .{clip(r2, 800)}) catch {};
    w.flush() catch {};
}

/// Pixel RAG Phase A smoke: pixel_ingest a url (render → tile → index) then pixel_search a query, through
/// tools.execute. Requires NL_BROWSER_DRIVER=1. Prints both results + confirms tile PNGs were written.
pub fn pixelSmoke(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, home: []const u8, data: []const u8, url: []const u8, query: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ home, NEURON_EXE }) catch "";
    const run_dir = std.fmt.allocPrint(gpa, "{s}/pixel-smoke", .{data}) catch return;
    defer gpa.free(run_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{run_dir}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .run_dir = run_dir,
        .workdir = run_dir,
        .scope = "pixel",
        .mind = "pixel",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
    };

    const ing_args = std.json.Stringify.valueAlloc(gpa, .{ .url = url }, .{}) catch return;
    defer gpa.free(ing_args);
    const r1 = tools.execute(&ctx, "pixel_ingest", ing_args);
    defer if (r1.len > 0) gpa.free(r1);
    w.print("--- pixel_ingest ---\n{s}\n", .{clip(r1, 600)}) catch {};
    w.flush() catch {};

    const q_args = std.json.Stringify.valueAlloc(gpa, .{ .query = query, .k = 3 }, .{}) catch return;
    defer gpa.free(q_args);
    const r2 = tools.execute(&ctx, "pixel_search", q_args);
    defer if (r2.len > 0) gpa.free(r2);
    w.print("--- pixel_search \"{s}\" ---\n{s}\n", .{ query, clip(r2, 1600) }) catch {};
    w.flush() catch {};
}

const MOCK_MCP_PY =
    \\import sys, json
    \\def send(o): sys.stdout.write(json.dumps(o)+"\n"); sys.stdout.flush()
    \\for line in sys.stdin:
    \\    line=line.strip()
    \\    if not line: continue
    \\    try: msg=json.loads(line)
    \\    except: continue
    \\    mid=msg.get("id"); method=msg.get("method")
    \\    if method=="initialize":
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"mock","version":"1.0"}}})
    \\    elif method=="tools/list":
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"echo","description":"echo back text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}})
    \\    elif method=="tools/call":
    \\        args=(msg.get("params") or {}).get("arguments") or {}
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"echo: "+str(args.get("text",""))}]}})
    \\    elif mid is not None:
    \\        send({"jsonrpc":"2.0","id":mid,"result":{}})
;

/// MCP layer smoke: (a) mcp_discover through tools.execute (scans the machine's real MCP configs + probes local
/// AI ports); (b) the MCP stdio client against a mock server (initialize → tools/list → tools/call). Requires
/// NL_MCP=1 for part (a).
pub fn mcpSmoke(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, home: []const u8, data: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var nb: [700]u8 = undefined;
    const neuron_bin = std.fmt.bufPrint(&nb, "{s}/bin/{s}", .{ home, NEURON_EXE }) catch "";
    const run_dir = std.fmt.allocPrint(gpa, "{s}/mcp-smoke", .{data}) catch return;
    defer gpa.free(run_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{run_dir}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .run_dir = run_dir,
        .workdir = run_dir,
        .scope = "mcp",
        .mind = "mcp",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &fmtx,
    };
    const disc = tools.execute(&ctx, "mcp_discover", "{}");
    defer if (disc.len > 0) gpa.free(disc);
    w.print("--- mcp_discover (scan configs + probe ports) ---\n{s}\n", .{clip(disc, 1400)}) catch {};
    w.flush() catch {};

    // Mock stdio MCP server for the client protocol test.
    const mock = std.fmt.allocPrint(gpa, "{s}/mcp-mock.py", .{run_dir}) catch return;
    defer gpa.free(mock);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = mock, .data = MOCK_MCP_PY }) catch {};
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const srv = mcp_client.Server{ .command = py, .args = &.{mock} };
    const tl = mcp_client.listStdio(gpa, io, environ, srv, 30);
    defer if (tl.len > 0) gpa.free(tl);
    w.print("--- mcp client: tools/list (mock) ---\n{s}\n", .{clip(tl, 800)}) catch {};
    const cr = mcp_client.callStdio(gpa, io, environ, srv, "echo", "{\"text\":\"hello mcp\"}");
    defer if (cr.len > 0) gpa.free(cr);
    w.print("--- mcp client: tools/call echo (mock) ---\n{s}\n", .{clip(cr, 800)}) catch {};
    w.flush() catch {};
}

/// `veil exec-tool <name> [--workdir DIR] [--args-file PATH]` — args JSON from PATH (or stdin), result on
/// stdout. The subprocess form a non-Zig client (the desk) uses to reach the shared executor; defaults the
/// workdir to the current directory. `--args-file` avoids stdin plumbing for a caller that spawns+captures with
/// a simple run() helper (the desk writes the args to a temp file in the build dir and passes its path here).
pub fn cmd(ctx: *cli.Ctx, args: []const []const u8) u8 {
    if (args.len == 0) {
        std.debug.print("usage: veil exec-tool <tool-name> [--workdir DIR] [--args-file PATH]   (else args JSON on stdin)\n", .{});
        return 1;
    }
    const name = args[0];
    var workdir: []const u8 = ".";
    var args_file: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workdir") and i + 1 < args.len) {
            i += 1;
            workdir = args[i];
        } else if (std.mem.eql(u8, args[i], "--args-file") and i + 1 < args.len) {
            i += 1;
            args_file = args[i];
        }
    }
    // args source: an --args-file (preferred by the desk) else stdin. Either can carry a large write_file payload.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(ctx.gpa);
    if (args_file.len > 0) {
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, args_file, ctx.gpa, .limited(8 << 20)) catch |e| {
            std.debug.print("exec-tool: cannot read --args-file {s}: {s}\n", .{ args_file, @errorName(e) });
            return 1;
        };
        body.appendSlice(ctx.gpa, data) catch {};
        ctx.gpa.free(data);
    } else {
        const stdin = std.Io.File.stdin();
        var chunk: [4096]u8 = undefined;
        while (true) {
            var bufs = [_][]u8{&chunk};
            const n = stdin.readStreaming(ctx.io, &bufs) catch break;
            if (n == 0) break;
            body.appendSlice(ctx.gpa, chunk[0..n]) catch break;
        }
    }
    const args_json = if (body.items.len > 0) body.items else "{}";
    const result = runTool(ctx, workdir, name, args_json);
    defer ctx.gpa.free(result);
    cli.out("{s}", .{result}); // result to STDOUT so the caller captures it
    return 0;
}

/// `veil sync-manifest [--workdir DIR]` — print the workdir's sync manifest response (probe echo + file
/// hashes; see worker/chat/sync.zig). The subprocess form the desk uses to answer a {kind:"sync_request"}
/// frame — same one implementation the CLI chat calls in-process. A non-"." workdir must be a SAFE absolute
/// path (a conv workdir or a sync_dir projection root) — anything else answers an empty manifest.
pub fn cmdSyncManifest(ctx: *cli.Ctx, args: []const []const u8) u8 {
    const wd = argWorkdir(args);
    if (!std.mem.eql(u8, wd, ".") and !cync.safeRoot(wd)) {
        cli.out("{s}", .{"{\"probe\":\"\",\"files\":[]}"});
        return 0;
    }
    const resp = cync.manifestResponse(ctx.gpa, ctx.io, wd);
    defer ctx.gpa.free(resp);
    cli.out("{s}", .{resp});
    return 0;
}

/// `veil sync-read --args-file PATH [--workdir DIR]` — read the files a {kind:"file_pull"} frame names (the
/// frame JSON is the args file) and print the batched contents response. Desk twin of the CLI's in-process
/// handler.
pub fn cmdSyncRead(ctx: *cli.Ctx, args: []const []const u8) u8 {
    const wd = argWorkdir(args);
    if (!std.mem.eql(u8, wd, ".") and !cync.safeRoot(wd)) {
        cli.out("{s}", .{"{\"files\":[]}"});
        return 0;
    }
    var frame: []const u8 = "{}";
    var owned: ?[]u8 = null;
    defer if (owned) |o| ctx.gpa.free(o);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--args-file") and i + 1 < args.len) {
            i += 1;
            if (std.Io.Dir.cwd().readFileAlloc(ctx.io, args[i], ctx.gpa, .limited(1 << 20)) catch null) |data| {
                owned = data;
                frame = data;
            }
        }
    }
    const resp = cync.readResponse(ctx.gpa, ctx.io, wd, frame);
    defer ctx.gpa.free(resp);
    cli.out("{s}", .{resp});
    return 0;
}

/// The `--workdir DIR` argument, defaulting to the current directory.
fn argWorkdir(args: []const []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workdir") and i + 1 < args.len) return args[i + 1];
    }
    return ".";
}
