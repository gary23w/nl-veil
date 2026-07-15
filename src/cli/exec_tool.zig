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
