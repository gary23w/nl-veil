//! A child process run under a bound that holds on every platform, with both of its streams kept.
//!
//! WHY NOT std.process.run's `.timeout`. On Windows it is no bound for a child that prints nothing. run's
//! MultiReader.fill returns error.Timeout on time, but run's deferred `multi_reader.deinit()` runs BEFORE its
//! deferred `child.kill()`, and Io.Threaded's Windows batchCancel waits for an APC (an INFINITE alertable
//! NtDelayExecution) BEFORE it cancels the pending pipe reads. A child that still holds its pipes and prints
//! nothing delivers no APC, so deinit waits for it to exit on its own, and only then is it killed. Measured
//! 2026-10-14 on Zig 0.16: a 1 s `.timeout` on a silent `cmd /C "ping -n 6 127.0.0.1 >NUL"` came back after
//! 5099 ms, while a child printing a line a second came back on time, each line delivering an APC. And a
//! `.duration` timeout restarts at every fill, so even where it works it bounds the silence between reads, not
//! the run: a child that prints steadily is never cut at all. Its output limits hang outright: past stdout_limit
//! run returns StreamTooLong with stdout's next read only queued (Batch.addAt issues it at the next await), so
//! deinit waits on stderr's read alone; with stderr silent nothing ever arrives, and the child blocks forever on
//! its full stdout pipe (measured: a looping `echo` sat there 8 minutes until killed by hand).
//!
//! So run() reads both pipes itself under ONE deadline for the whole run. At it, or past an output limit, the
//! child is killed with everything it started (killTree), and on Windows our own pending reads are cancelled
//! (CancelIoEx) BEFORE the reader's deinit, so its batch cancel finds the APCs it waits for. POSIX's batch
//! cancel only frees poll storage; the tree kill is what it gains.
//!
//! NOT bounded: a child that closes both pipes and keeps running is waited for (child.wait), as std.process.run
//! waited for it.
const std = @import("std");
const builtin = @import("builtin");

const win = builtin.os.tag == .windows;

extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetProcessId(hProcess: *anyopaque) callconv(.winapi) u32; // Child.Id is a HANDLE; taskkill wants the pid
extern "kernel32" fn CancelIoEx(hFile: *anyopaque, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;

/// TEST SEAM: `cap_ms` caps every bound, so a test can drive a caller whose real bound is minutes (the 240 s
/// declared checks) to its cut in a second.
pub const seam = if (builtin.is_test) struct {
    pub var cap_ms: ?u64 = null;
} else struct {};

pub const Options = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    /// The child's whole environment; null = this process's own, as std.process.run.
    environ_map: ?*const std.process.Environ.Map = null,
    /// The bound: the whole run, spawn to exit, in milliseconds. Output never extends it.
    bound_ms: u64,
    /// stdout past this many bytes ends the run as `.overflow` (std.process.run's stdout_limit, whose
    /// StreamTooLong also ended it), unless `head_tail`.
    stdout_limit: usize,
    /// The same for stderr, unless `stderr_tail` or `head_tail`.
    stderr_limit: usize,
    /// Keep only stderr's TAIL instead, so it never ends the run: past 4x stderr_limit it is cut back to its last
    /// stderr_limit bytes. For a caller that shows stderr only as a tail, where a progress bar must not grow it
    /// unbounded.
    stderr_tail: bool = false,
    /// Keep the HEAD and TAIL of both streams instead, so neither ever ends the run: past its limit a stream's first
    /// `limit` bytes are set aside and the rest is cut back as stderr_tail's is. What a stream kept is its first and
    /// last `limit` bytes with one line between them naming how many bytes were not kept (all of it, when it printed
    /// no more than 2x its limit). For a caller that scores a run by its exit code however much it printed, and reads
    /// both ends of its output: a compiler's first error is at the top, a test runner's summary at the bottom.
    /// Overrides stderr_tail.
    head_tail: bool = false,
};

/// How a run ended. `.killed` = still running at the bound; `.overflow` = printed past a limit (never under
/// `head_tail`); `.unread` = its output could not be read or its exit not collected; `.unstarted` = the spawn failed.
/// `.killed`, `.overflow` and `.unread` were killed with everything they started.
pub const End = enum { exited, signal, killed, overflow, unread, unstarted };

pub const Result = struct {
    end: End = .unstarted,
    /// The exit code, when `end == .exited`.
    code: u32 = 0,
    /// What it printed, up to its end. Both gpa-owned (possibly empty); deinit frees them.
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    /// The error behind `.unstarted` (the spawn's own, so deps.isSpawnMissing can tell a missing program from one
    /// that failed) or `.unread`.
    err: ?anyerror = null,

    pub fn deinit(r: *Result, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    pub fn ok(r: *const Result) bool {
        return r.end == .exited and r.code == 0;
    }
    /// The exit code when the child exited on its own; null for any other end.
    pub fn exited(r: *const Result) ?u32 {
        return if (r.end == .exited) r.code else null;
    }
    /// The child ran to its own end, exit or signal: exactly the runs std.process.run returned a RunResult for.
    pub fn finished(r: *const Result) bool {
        return r.end == .exited or r.end == .signal;
    }
    pub fn why(r: *const Result) []const u8 {
        return if (r.err) |e| @errorName(e) else "";
    }
};

/// One stream kept as its head and tail (Options.head_tail).
const Ends = struct {
    /// Its first `limit` bytes, gpa-owned, set aside once it passed its limit. Empty before that, and also after
    /// should that copy fail, when the stream is kept as a plain tail.
    head: []u8 = &.{},
    taken: bool = false,
    /// Bytes tossed from the reader after the head.
    dropped: usize = 0,

    /// After each fill: past `limit`, set the head aside once, then cut what follows it back to its last `limit`
    /// bytes whenever it passes 4x that, as stderr_tail does.
    fn trim(e: *Ends, gpa: std.mem.Allocator, rd: *std.Io.Reader, limit: usize) void {
        if (rd.buffered().len <= limit) return;
        if (!e.taken) {
            e.taken = true;
            if (gpa.dupe(u8, rd.buffered()[0..limit])) |h| {
                e.head = h;
                rd.toss(limit);
            } else |_| {}
        }
        const n = rd.buffered().len;
        if (n > 4 * limit) {
            rd.toss(n - limit);
            e.dropped += n - limit;
        }
    }

    /// What the stream kept, gpa-owned: the head, a line naming how many bytes were not kept, and the last `limit`
    /// bytes of `rest` (what the reader still holds); the head and `rest` whole when nothing was dropped. Each side
    /// of the cut is cut back to whole lines where a line ends within 512 bytes of it, so a caller reading lines
    /// (checkDiag, errorHeaders) never meets half of one there.
    fn join(e: *const Ends, gpa: std.mem.Allocator, rest: []const u8, limit: usize) []u8 {
        if (e.head.len == 0) return gpa.dupe(u8, rest) catch &.{};
        const tail = rest[rest.len -| limit..];
        if (e.dropped == 0 and tail.len == rest.len) return std.mem.concat(gpa, u8, &.{ e.head, rest }) catch &.{};
        const hs = e.head.len -| 512;
        const h = if (std.mem.lastIndexOfScalar(u8, e.head[hs..], '\n')) |i| e.head[0 .. hs + i + 1] else e.head;
        const t = if (std.mem.indexOfScalar(u8, tail[0..@min(tail.len, 512)], '\n')) |i| tail[i + 1 ..] else tail;
        const not_kept = e.head.len + e.dropped + rest.len - h.len - t.len;
        var mb: [64]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "[... {d} bytes not kept ...]\n", .{not_kept}) catch "";
        const nl: []const u8 = if (h.len > 0 and h[h.len - 1] != '\n') "\n" else "";
        return std.mem.concat(gpa, u8, &.{ h, nl, mark, t }) catch &.{};
    }
};

/// Run `o.argv` to its end or its bound, whichever comes first, with both streams captured. Never fails: how it
/// ended is `end`. stdin is closed (`.ignore`) and no console window opens on Windows.
pub fn run(gpa: std.mem.Allocator, io: std.Io, o: Options) Result {
    const bound_ms = if (builtin.is_test) @min(o.bound_ms, seam.cap_ms orelse o.bound_ms) else o.bound_ms;
    // POSIX: its own process group, so killTree reaches what the child started. dash does not exec a nested
    // `sh -c` either: measured in WSL, killing the direct child alone left `sh -c sleep 6` and its sleep running.
    // The cost, accepted: a terminal's Ctrl-C signals only its foreground group, so it no longer reaches the child.
    var child = std.process.spawn(io, .{
        .argv = o.argv,
        .cwd = o.cwd,
        .environ_map = o.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
        .pgid = if (win) null else 0,
    }) catch |e| return .{ .err = e };
    defer child.kill(io);
    var bufs: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, bufs.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out = mr.reader(0);
    const er = mr.reader(1);
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(@intCast(bound_ms)), .clock = .awake } }).toDeadline(io);
    var ends: [2]Ends = .{ .{}, .{} }; // stdout, stderr under head_tail
    defer for (ends) |e| gpa.free(e.head);
    var r: Result = .{ .end = .exited };
    while (mr.fill(256, deadline)) |_| {
        if (o.head_tail) {
            ends[0].trim(gpa, out, o.stdout_limit);
            ends[1].trim(gpa, er, o.stderr_limit);
            continue;
        }
        if (out.buffered().len > o.stdout_limit) {
            r.end = .overflow;
            break;
        }
        if (er.buffered().len > o.stderr_limit) {
            if (!o.stderr_tail) {
                r.end = .overflow;
                break;
            }
            if (er.buffered().len > 4 * o.stderr_limit) er.toss(er.buffered().len - o.stderr_limit);
        }
    } else |e| switch (e) {
        // both streams are done; one that ended on a read error rather than EOF says so here
        error.EndOfStream => mr.checkAnyError() catch |re| {
            r.end = .unread;
            r.err = re;
        },
        error.Timeout => r.end = .killed,
        else => {
            r.end = .unread;
            r.err = e;
        },
    }
    // COPIES, never mr.toOwnedSlice. On Windows a run cut at its bound or a limit still has its overlapped pipe
    // reads pending in the kernel, aimed past the buffered bytes of these very buffers; toOwnedSlice reallocs or
    // frees them on the spot, so whatever the child printed during the tree kill below was copied by the kernel into
    // heap we no longer owned (measured: a still-printing probe's bytes turned up in released blocks under a
    // quarantine allocator). The buffers stay the MultiReader's until its deferred deinit, whose batch cancel drains
    // those reads before it frees anything.
    r.stdout = if (o.head_tail) ends[0].join(gpa, out.buffered(), o.stdout_limit) else gpa.dupe(u8, out.buffered()) catch &.{};
    r.stderr = if (o.head_tail) ends[1].join(gpa, er.buffered(), o.stderr_limit) else gpa.dupe(u8, er.buffered()) catch &.{};
    if (r.end != .exited) {
        killTree(io, &child); // then the deferred child.kill reaps the direct child
        // Cancelled HERE, before the deferred deinit: its Windows batch cancel waits for an APC before it cancels
        // anything (see the file comment). The tree kill closes the pipes; cancelling our own reads covers a holder
        // that escaped it, so the bound stays a bound.
        if (win) {
            _ = CancelIoEx(child.stdout.?.handle, null);
            _ = CancelIoEx(child.stderr.?.handle, null);
        }
        return r;
    }
    const term = child.wait(io) catch |e| {
        r.end = .unread;
        r.err = e;
        return r;
    };
    switch (term) {
        .exited => |c| r.code = c,
        else => r.end = .signal,
    }
    return r;
}

/// Kill `child` and everything it started; the caller still reaps `child` itself (child.kill or child.wait).
/// Windows: `taskkill /F /T` on its pid, because cmd.exe never execs, so a shell's grandchild outlives a kill of the
/// shell alone (measured 2026-10-14: a ping under cmd did), and keeps the pipes open. spawnGuarded, not
/// std.process.run, because the latter is not a bound on Windows (see the file comment): a taskkill stuck
/// mid-enumeration is terminated by handle at 10 s. POSIX: the process group the child leads (run() spawns it as a
/// group leader), then the child itself, should the group signal be refused or the child lead no group.
pub fn killTree(io: std.Io, child: *const std.process.Child) void {
    const h = child.id orelse return;
    if (win) {
        var pb: [16]u8 = undefined;
        const ps = std.fmt.bufPrint(&pb, "{d}", .{GetProcessId(h)}) catch return;
        _ = spawnGuarded(io, &.{ "taskkill", "/F", "/T", "/PID", ps }, 10_000);
    } else {
        std.posix.kill(-h, .KILL) catch {};
        std.posix.kill(h, .KILL) catch {};
    }
}

const KillGuard = struct {
    id: std.process.Child.Id,
    deadline_ms: u32,
    done: *std.atomic.Value(bool),
    fn watch(g: KillGuard) void {
        var waited: u32 = 0;
        while (waited < g.deadline_ms) : (waited += 150) {
            if (win) {
                Sleep(150);
            } else {
                const ts = std.posix.timespec{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null); // libc, not os.linux — ports to macOS (see browser/util.sleepMs)
            }
            if (g.done.load(.monotonic)) return;
        }
        if (g.done.load(.monotonic)) return;
        if (win) {
            _ = TerminateProcess(@ptrCast(g.id), 1);
        } else std.posix.kill(g.id, .KILL) catch {};
    }
};

/// Spawn a subprocess (its body redirected to a file via the caller's argv, so stdout never blocks the read) and KILL
/// it by handle if it runs longer than `deadline_ms` — so a WAF-held curl self-heals (the tool returns whatever
/// arrived) instead of wedging the swarm. The watchdog holds a COPY of the handle (captured before spawn) so it never
/// races the main thread's wait(); TerminateProcess on an already-closed handle is harmless.
/// Returns the SPAWN error if the child could not be started (so a caller can tell a MISSING curl from a
/// curl that ran and returned nothing — see deps.isSpawnMissing), else null on a successful spawn+wait.
pub fn spawnGuarded(io: std.Io, argv: []const []const u8, deadline_ms: u32) ?anyerror {
    // create_no_window: on Windows a bare spawn of a console app (curl.exe) from a windowless parent pops a
    // console that flashes on the user's desktop for each fetch. std.process.run already defaults this true;
    // std.process.spawn defaults it FALSE, so set it explicitly here (no-op off Windows).
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch |e| return e;
    var done = std.atomic.Value(bool).init(false);
    const th: ?std.Thread = if (child.id != null)
        (std.Thread.spawn(.{}, KillGuard.watch, .{KillGuard{ .id = child.id.?, .deadline_ms = deadline_ms, .done = &done }}) catch null)
    else
        null;
    _ = child.wait(io) catch {};
    done.store(true, .monotonic);
    if (th) |t| t.join();
    return null;
}

/// Test-only: an Io over the REAL process environment (TESTING.md: an empty one leaves a Windows child without
/// SystemRoot/PATH), and a fresh cwd-relative scratch dir the caller defers deleting.
const Fixture = struct {
    threaded: std.Io.Threaded,

    fn init(f: *Fixture, gpa: std.mem.Allocator, root: []const u8) void {
        const environ: std.process.Environ = if (win)
            .{ .block = .global }
        else
            .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
        f.threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
        const io = f.threaded.io();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    }
    fn deinit(f: *Fixture, root: []const u8) void {
        std.Io.Dir.cwd().deleteTree(f.threaded.io(), root) catch {};
        f.threaded.deinit();
    }
};

/// Test-only: a shell running `script` the way the callers' rows run (cmd /C, sh -c).
fn shell(script: []const u8) [3][]const u8 {
    return if (win) .{ "cmd", "/C", script } else .{ "/bin/sh", "-c", script };
}

/// Test-only: the proof that nothing a cut run started is still alive. Windows: `held` was a file the run's
/// grandchild held open by redirect (cmd's redirect shares no delete), so it deletes only once that process is gone
/// (retried briefly while the killed tree's handles close). POSIX: `held` was a heartbeat the grandchild kept
/// growing, so its size stops changing.
pub fn expectTreeGone(io: std.Io, held: []const u8) !void {
    if (win) {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (std.Io.Dir.cwd().deleteFile(io, held)) |_| return else |e| {
                if (e == error.FileNotFound or tries >= 40) return e; // FileNotFound = it never ran: no proof
                io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
            }
        }
    }
    const s1 = (try std.Io.Dir.cwd().statFile(io, held, .{})).size;
    io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    const s2 = (try std.Io.Dir.cwd().statFile(io, held, .{})).size;
    try std.testing.expect(s1 > 0);
    try std.testing.expectEqual(s1, s2);
}

test "a child silent on its pipes is cut at the bound with everything it started, not waited out (real shell)" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-silent-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();
    // The measured failure: nothing reaches the pipes (ping's output goes to a file, the loop's to a heartbeat), and
    // the real work runs a level below the shell. end.txt is written only by a natural end, ~30 s out, so finding it
    // means the run was waited out rather than cut.
    const script = if (win)
        "ping -n 30 127.0.0.1 >" ++ root ++ "\\held.txt 2>&1 & echo natural>" ++ root ++ "\\end.txt"
    else
        "sh -c 'i=0; while [ $i -lt 300 ]; do echo x >> " ++ root ++ "/held.txt; i=$((i+1)); sleep 0.1; done'; echo natural > " ++ root ++ "/end.txt";
    const argv = shell(script);
    var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 1000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(End.killed, r.end);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root ++ "/end.txt", .{}));
    try expectTreeGone(io, root ++ "/held.txt");
}

test "a run whose pipes are held by a process the tree kill cannot reach still ends at its bound (real shell, Windows)" {
    // POSIX's batch cancel never waits on the pipes, and a background job stays in the group run() kills: no escape
    if (!win) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const root = "zig-bounded-escaped-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();
    // `start /B` hands ping the shell's handles, our pipes among them, and returns at once: the shell exits, ping is
    // left an orphan, and taskkill /T on the shell's pid no longer reaches it. ping prints nothing to the pipes (its
    // stdout is held.txt, which it holds open) and lives ~5 s. So the tree kill closes nothing here, and only our own
    // cancel of the pending reads lets the reader's deinit return before ping does.
    const argv = shell("start /B ping -n 6 127.0.0.1 >" ++ root ++ "\\held.txt");
    var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 1000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(End.killed, r.end);
    // run() came back while ping still held its file; had it waited ping out, the file would delete at once
    _ = try std.Io.Dir.cwd().statFile(io, root ++ "/held.txt", .{});
    if (std.Io.Dir.cwd().deleteFile(io, root ++ "/held.txt")) |_| return error.RunWaitedForTheHolder else |_| {}
    // the orphan is out of reach, so let it run out before the scratch dir goes
    var tries: u32 = 0;
    while (tries < 300) : (tries += 1) {
        if (std.Io.Dir.cwd().deleteFile(io, root ++ "/held.txt")) |_| break else |_| {}
        io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

test "a child that keeps printing is cut at the same bound: one deadline for the whole run, not a silence timer (real shell)" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-chatty-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();
    // A tick about every second for ~30 s. A `.duration` timeout of 3 s restarts at every tick and so never fires;
    // the run would go on to its natural end and write end.txt.
    const script = if (win)
        "(for /L %i in (1,1,30) do @(echo tick %i& ping -n 2 127.0.0.1 >NUL))& echo natural>" ++ root ++ "\\end.txt"
    else
        "i=0; while [ $i -lt 30 ]; do echo tick $i; i=$((i+1)); sleep 1; done; echo natural > " ++ root ++ "/end.txt";
    const argv = shell(script);
    var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 3000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(End.killed, r.end);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "tick 1") != null); // what it printed before the cut is kept
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root ++ "/end.txt", .{}));
}

test "a run that ends inside its bound keeps both streams and its own exit code (real shell)" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-exit-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const argv = shell(if (win) "echo out-line& echo err-line 1>&2& exit /b 3" else "echo out-line; echo err-line >&2; exit 3");
    var r = run(gpa, f.threaded.io(), .{ .argv = &argv, .bound_ms = 30_000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(End.exited, r.end);
    try std.testing.expectEqual(@as(?u32, 3), r.exited());
    try std.testing.expect(r.finished() and !r.ok());
    try std.testing.expectEqualStrings("out-line", std.mem.trim(u8, r.stdout, " \r\n"));
    try std.testing.expectEqualStrings("err-line", std.mem.trim(u8, r.stderr, " \r\n"));
}

test "stdout past its limit ends the run as an overflow, as StreamTooLong did; stderr kept as a tail never does (real shell)" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-limit-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();
    {
        // far more than the limit, for far longer than this test: only the limit can end it this soon
        const argv = shell(if (win) "for /L %i in (1,1,200000) do @echo 0123456789" else "i=0; while [ $i -lt 200000 ]; do echo 0123456789; i=$((i+1)); done");
        var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 60_000, .stdout_limit = 1024, .stderr_limit = 1024 });
        defer r.deinit(gpa);
        try std.testing.expectEqual(End.overflow, r.end);
        try std.testing.expect(r.stdout.len > 1024 and !r.finished());
    }
    {
        // ~14 KB of stderr against a 64-byte limit, then the line that matters
        const argv = shell(if (win) "(for /L %i in (1,1,2000) do @echo e%i 1>&2)& echo LAST 1>&2" else "i=0; while [ $i -lt 2000 ]; do echo e$i >&2; i=$((i+1)); done; echo LAST >&2");
        var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 60_000, .stdout_limit = 1024, .stderr_limit = 64, .stderr_tail = true });
        defer r.deinit(gpa);
        try std.testing.expectEqual(End.exited, r.end);
        try std.testing.expect(r.stderr.len <= 4 * 64 + 4096); // a tail: at most one read past the trim point
        try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, r.stderr, " \r\n"), "LAST"));
    }
}

test "head_tail runs a stream to its exit however much it prints, keeps both ends, and names every byte it did not keep (real shell)" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-headtail-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();
    const nl = if (win) "\r\n" else "\n";
    {
        // ~36 KB on each stream against 1 KB limits, far past every trim point, then the run's own exit code
        const argv = shell(if (win)
            "echo FIRST& (for /L %i in (1,1,3000) do @echo 0123456789)& echo LAST& echo EFIRST 1>&2& (for /L %i in (1,1,3000) do @echo 0123456789 1>&2)& echo ELAST 1>&2& exit /b 5"
        else
            "echo FIRST; i=0; while [ $i -lt 3000 ]; do echo 0123456789; i=$((i+1)); done; echo LAST; echo EFIRST >&2; i=0; while [ $i -lt 3000 ]; do echo 0123456789 >&2; i=$((i+1)); done; echo ELAST >&2; exit 5");
        var r = run(gpa, io, .{ .argv = &argv, .bound_ms = 60_000, .stdout_limit = 1024, .stderr_limit = 1024, .head_tail = true });
        defer r.deinit(gpa);
        try std.testing.expectEqual(End.exited, r.end);
        try std.testing.expectEqual(@as(?u32, 5), r.exited());
        try std.testing.expect(std.mem.startsWith(u8, r.stdout, "FIRST" ++ nl) and std.mem.endsWith(u8, r.stdout, "LAST" ++ nl));
        try std.testing.expect(std.mem.startsWith(u8, r.stderr, "EFIRST") and std.mem.endsWith(u8, std.mem.trimEnd(u8, r.stderr, " \r\n"), "ELAST"));
        try std.testing.expect(r.stdout.len <= 2 * 1024 + 64 and r.stderr.len <= 2 * 1024 + 64);
        // What it kept plus what the marker line says it did not keep is exactly what the script printed, and the
        // cut fell between whole lines on both sides.
        const printed = ("FIRST" ++ nl).len + 3000 * ("0123456789" ++ nl).len + ("LAST" ++ nl).len;
        const at = std.mem.indexOf(u8, r.stdout, "\n[... ") orelse return error.NoMarker;
        const line_end = std.mem.indexOfScalarPos(u8, r.stdout, at + 1, '\n') orelse return error.NoMarker;
        const mark = r.stdout[at + 1 .. line_end + 1];
        try std.testing.expect(std.mem.endsWith(u8, mark, " bytes not kept ...]\n"));
        const num_end = std.mem.indexOfScalarPos(u8, mark, "[... ".len, ' ') orelse return error.NoMarker;
        const not_kept = try std.fmt.parseInt(usize, mark["[... ".len..num_end], 10);
        try std.testing.expectEqual(printed, r.stdout.len - mark.len + not_kept);
        try std.testing.expect(std.mem.endsWith(u8, r.stdout[0 .. at + 1], "0123456789" ++ nl));
        try std.testing.expect(std.mem.startsWith(u8, r.stdout[line_end + 1 ..], "0123456789" ++ nl));
    }
    {
        // ~1.4 KB against a 1 KB limit: the head is set aside but nothing is dropped, so what it kept is byte for byte
        // what an uncapped run of the same script keeps
        const argv = shell(if (win) "for /L %i in (1,1,125) do @echo 0123456789" else "i=0; while [ $i -lt 125 ]; do echo 0123456789; i=$((i+1)); done");
        var whole = run(gpa, io, .{ .argv = &argv, .bound_ms = 60_000, .stdout_limit = 1 << 20, .stderr_limit = 1024 });
        defer whole.deinit(gpa);
        var kept = run(gpa, io, .{ .argv = &argv, .bound_ms = 60_000, .stdout_limit = 1024, .stderr_limit = 1024, .head_tail = true });
        defer kept.deinit(gpa);
        try std.testing.expectEqual(End.exited, kept.end);
        try std.testing.expect(whole.stdout.len > 1024 and whole.stdout.len <= 2 * 1024);
        try std.testing.expectEqualStrings(whole.stdout, kept.stdout);
    }
}

test "a program that is not there reads as unstarted with the spawn's own error, so a missing one is told apart from a failing one" {
    const gpa = std.testing.allocator;
    const root = "zig-bounded-missing-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    var r = run(gpa, f.threaded.io(), .{ .argv = &.{"nl-bounded-no-such-program"}, .bound_ms = 30_000, .stdout_limit = 64, .stderr_limit = 64 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(End.unstarted, r.end);
    try std.testing.expect(@import("deps.zig").isSpawnMissing(r.err.?));
    try std.testing.expect(!r.finished() and r.exited() == null);
}
