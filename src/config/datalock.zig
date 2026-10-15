//! datalock.zig — one server per data dir, enforced. A veil about to SERVE a data dir (server-only, app mode,
//! the desk's in-process server) takes `<data>/.veil.lock` before it touches anything else there, and a later
//! start that finds the dir held is told who holds it: pid, port and bind address.
//!
//! WHY. Measured twice on 2026-10-14 (data/veil-desk.log, UTC 20:18 and 22:38): a server-only veil was serving a
//! long turn on 127.0.0.1:8787 when the desk app was started on the same data dir. The desk's in-process server
//! bound 0.0.0.0:8787 beside it, the first listener stopped answering for ~15 s, and from then on the second
//! server answered the first one's client out of the shared data dir while the original turn was dead. Both
//! shared the vault, the OAuth token and files.jsonl for minutes; an earlier run of the same collision
//! overwrote data/.desktop_key (2026-09-22). The port is not the guard: Windows let the second bind succeed
//! beside the first. The data dir is.
//!
//! THE LOCK is the operating system's, not a pid file's. Windows: the holder opens the file sharing READ only,
//! so a second open for writing is refused with a sharing violation for as long as any process holds it, and the
//! handle dies with the process. POSIX: flock(LOCK_EX|LOCK_NB) on the open file, released by the kernel when the
//! holder exits however it exits. Either way a crash leaves a file nobody holds, and the next start takes it:
//! the pid written inside is for the refusal message, never the gate. A reader may always open the file for
//! reading (the holder shares read), so the refusal can name the holder.
//!
//! NOT a byte-range lock (Windows NtLockFile, what std's `lock = .exclusive` does there): that lock is mandatory
//! for every other handle, so the second veil could not read the pid and port it is refused for.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// The lock file's name under the data dir.
pub const FILE_NAME = ".veil.lock";
/// Longest data dir path the lock serves (the file name rides on top).
const DIR_CAP = 4096;
const PATH_CAP = DIR_CAP + 1 + FILE_NAME.len;
/// The sharing violation came from no live veil on record (an unrelated process reading the file, or a holder
/// that has opened but not yet written): look again this many times, this far apart, before reporting it held.
const UNKNOWN_HOLDER_RETRIES: u32 = 10;
const UNKNOWN_HOLDER_RETRY_MS: u32 = 50;
/// The lock file never holds more than this: three short `key=value` lines.
const RECORD_CAP = 256;

/// Who holds a data dir, as the holder wrote it. `pid == 0` = held, but by a process that left no record (see
/// `take`); `port == 0` likewise means unknown.
pub const Holder = struct {
    pid: u32 = 0,
    port: u16 = 0,
    bind: [47]u8 = undefined,
    bind_len: u8 = 0,

    pub fn bindStr(h: *const Holder) []const u8 {
        return h.bind[0..h.bind_len];
    }
    /// The holder left a record (a veil that got as far as writing it).
    pub fn known(h: *const Holder) bool {
        return h.pid != 0;
    }
};

/// A taken lock: this process serves the dir until `release` or exit, whichever comes first.
pub const Lock = struct {
    impl: if (is_windows) std.os.windows.HANDLE else std.Io.File,
    path: [PATH_CAP]u8,
    path_len: usize,

    /// Let the dir go and remove the file. Order matters on POSIX: unlink THEN close. Closing first leaves a window
    /// where a newcomer opens the still-linked inode and locks it, this unlink then removes the path from under it,
    /// and a third process creates and locks a fresh inode at the same path: two holders. Windows deletes after the
    /// close and loses nothing: a newcomer that already holds the file shares no delete, so the delete fails.
    pub fn release(self: *Lock, io: std.Io) void {
        const path = self.path[0..self.path_len];
        if (is_windows) {
            std.os.windows.CloseHandle(self.impl);
            var wbuf: [PATH_CAP + 1]u16 = undefined;
            if (toWide(&wbuf, path)) |wpath| _ = win.DeleteFileW(wpath) else |_| {}
        } else {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            self.impl.close(io);
        }
    }
};

pub const Outcome = union(enum) {
    /// Taken: serve. Hold it for the life of the process.
    taken: Lock,
    /// Another process serves this dir. Nothing was written.
    held: Holder,
};

pub const TakeError = error{ NameTooLong, BadPathName, AccessDenied, FileNotFound, Unexpected, OutOfMemory } ||
    std.Io.File.OpenError || std.Io.File.SetLengthError || std.Io.File.WritePositionalError;

/// Take the lock on `data_dir` for this process, recording `port` and `bind` for whoever is refused next. `held`
/// carries that record read back from the file; an error is a dir the lock file cannot be created in at all, which
/// the caller decides about (main serves unguarded and says so). Never blocks on a holder.
pub fn take(io: std.Io, data_dir: []const u8, port: u16, bind: []const u8) TakeError!Outcome {
    if (data_dir.len > DIR_CAP) return error.NameTooLong;
    var lock: Lock = .{ .impl = undefined, .path = undefined, .path_len = 0 };
    const path = std.fmt.bufPrint(&lock.path, "{s}/{s}", .{ data_dir, FILE_NAME }) catch return error.NameTooLong;
    lock.path_len = path.len;
    var record_buf: [RECORD_CAP]u8 = undefined;
    const record = std.fmt.bufPrint(&record_buf, "pid={d}\nport={d}\nbind={s}\n", .{ ownPid(), port, bind[0..@min(bind.len, 47)] }) catch unreachable;

    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (is_windows) {
            if (try takeWindows(path, record)) |h| {
                lock.impl = h;
                return .{ .taken = lock };
            }
        } else {
            if (try takePosix(io, path, record)) |f| {
                lock.impl = f;
                return .{ .taken = lock };
            }
        }
        // Held. Say by whom — and when no live veil is on record, look again briefly: a holder may be between
        // its open and its write, or (Windows) an unrelated process may be reading the file right now.
        const holder = holderOf(io, data_dir);
        if (holder.known() and pidAlive(holder.pid)) return .{ .held = holder };
        if (tries >= UNKNOWN_HOLDER_RETRIES) return .{ .held = holder };
        sleepMs(io, UNKNOWN_HOLDER_RETRY_MS);
    }
}

/// The record in `data_dir`'s lock file, whoever holds it (nobody, possibly). Always readable: the holder shares
/// read. A missing or unparseable file reads as an unknown holder.
pub fn holderOf(io: std.Io, data_dir: []const u8) Holder {
    var pbuf: [PATH_CAP]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ data_dir, FILE_NAME }) catch return .{};
    var buf: [RECORD_CAP]u8 = undefined;
    const n = if (is_windows) readWindows(path, &buf) else readPosix(io, path, &buf);
    return parseRecord(buf[0..n]);
}

/// This process's id, as the record names it.
pub fn ownPid() u32 {
    if (is_windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.posix.system.getpid());
}

/// Whether `pid` names a process that is still running. Any live process counts: the question here is whether the
/// record's writer is gone, not what it is. Windows: a handle to it that still reports STILL_ACTIVE. POSIX: a null
/// signal reaches it (EPERM = it exists but is not ours, which is still alive).
pub fn pidAlive(pid: u32) bool {
    if (pid == 0) return false;
    if (is_windows) {
        const h = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
        defer std.os.windows.CloseHandle(h);
        var code: u32 = 0;
        return win.GetExitCodeProcess(h, &code) != 0 and code == win.STILL_ACTIVE;
    } else {
        if (pid > std.math.maxInt(std.posix.pid_t)) return false; // no POSIX pid is that large; the cast below would trap
        std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |e| return e == error.PermissionDenied;
        return true;
    }
}

fn parseRecord(text: []const u8) Holder {
    var h: Holder = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "pid=")) {
            h.pid = std.fmt.parseInt(u32, line["pid=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "port=")) {
            h.port = std.fmt.parseInt(u16, line["port=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "bind=")) {
            const v = line["bind=".len..];
            const n = @min(v.len, h.bind.len);
            @memcpy(h.bind[0..n], v[0..n]);
            h.bind_len = @intCast(n);
        }
    }
    return h;
}

fn sleepMs(io: std.Io, ms: u32) void {
    if (is_windows) {
        win.Sleep(ms); // non-alertable, like main.zig's threadSleepMs: io.sleep parks on the runtime's alert
    } else {
        io.sleep(.{ .nanoseconds = @as(u64, ms) * std.time.ns_per_ms }, .awake) catch {};
    }
}

// ---- Windows: share-mode exclusion through CreateFileW ----

const win = if (is_windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    const BOOL = c_int;
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const FILE_SHARE_READ: u32 = 0x1;
    const FILE_SHARE_WRITE: u32 = 0x2;
    const FILE_SHARE_DELETE: u32 = 0x4;
    const CREATE_ALWAYS: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const STILL_ACTIVE: u32 = 259;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sec: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
} else struct {};

fn toWide(wbuf: *[PATH_CAP + 1]u16, path: []const u8) error{ NameTooLong, BadPathName }![:0]const u16 {
    const n = try std.os.windows.wtf8ToWtf16Le(wbuf[0..PATH_CAP], path);
    wbuf[n] = 0;
    return wbuf[0..n :0];
}

/// The holder's open: read+write access, sharing READ only, created or truncated. null = a sharing violation,
/// i.e. somebody holds it. The sharing check happens before any truncation, so a refused open changes nothing.
fn takeWindows(path: []const u8, record: []const u8) TakeError!?std.os.windows.HANDLE {
    var wbuf: [PATH_CAP + 1]u16 = undefined;
    const wpath = try toWide(&wbuf, path);
    const h = win.CreateFileW(wpath, win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) {
        return switch (std.os.windows.GetLastError()) {
            .SHARING_VIOLATION => null,
            .ACCESS_DENIED => error.AccessDenied,
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            else => |e| std.os.windows.unexpectedError(e),
        };
    }
    var written: u32 = 0;
    if (win.WriteFile(h, record.ptr, @intCast(record.len), &written, null) == 0 or written != record.len) {
        std.os.windows.CloseHandle(h);
        return error.Unexpected;
    }
    return h;
}

/// A reader's open: read access, sharing everything, so it is compatible with the holder's read+write access.
fn readWindows(path: []const u8, out: []u8) usize {
    var wbuf: [PATH_CAP + 1]u16 = undefined;
    const wpath = toWide(&wbuf, path) catch return 0;
    const h = win.CreateFileW(wpath, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return 0;
    defer std.os.windows.CloseHandle(h);
    var n: u32 = 0;
    if (win.ReadFile(h, out.ptr, @intCast(out.len), &n, null) == 0) return 0;
    return n;
}

// ---- POSIX: flock through std's own create-with-lock ----

/// null = the lock is held (flock refused it). The file is kept, not truncated, until the lock is ours.
fn takePosix(io: std.Io, path: []const u8, record: []const u8) TakeError!?std.Io.File {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |e| switch (e) {
        error.WouldBlock => return null,
        else => return e,
    };
    errdefer f.close(io);
    try f.setLength(io, 0);
    try f.writePositionalAll(io, record, 0);
    return f;
}

fn readPosix(io: std.Io, path: []const u8, out: []u8) usize {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    return f.readPositionalAll(io, out, 0) catch 0;
}

// ---------------------------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------------------------

/// Test-only: an Io over the REAL process environment (TESTING.md: an empty one leaves a Windows child without
/// SystemRoot/PATH), and a fresh cwd-relative scratch dir the caller defers deleting.
const Fixture = struct {
    threaded: std.Io.Threaded,

    fn init(f: *Fixture, gpa: std.mem.Allocator, root: []const u8) void {
        const environ: std.process.Environ = if (is_windows)
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

test "a data dir this process serves is refused to a second taker, who is told the holder's pid, port and bind" {
    const gpa = std.testing.allocator;
    const root = "zig-datalock-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();

    var first = try take(io, root, 8787, "127.0.0.1");
    try std.testing.expect(first == .taken);
    var first_held = true;
    defer if (first_held) first.taken.release(io); // a failed assertion must not leave the dir held for the next test
    // The record is readable while held: that is what the refusal below is made of.
    const on_disk = holderOf(io, root);
    try std.testing.expectEqual(ownPid(), on_disk.pid);
    try std.testing.expectEqual(@as(u16, 8787), on_disk.port);
    try std.testing.expectEqualStrings("127.0.0.1", on_disk.bindStr());

    // A second taker on the same dir — a second open, which is what a second process is to the lock — is refused
    // and told who holds it. Its own port and bind are NOT written: a refused take changes nothing.
    const second = try take(io, root, 9999, "0.0.0.0");
    try std.testing.expect(second == .held);
    try std.testing.expectEqual(ownPid(), second.held.pid);
    try std.testing.expectEqual(@as(u16, 8787), second.held.port);
    try std.testing.expectEqualStrings("127.0.0.1", second.held.bindStr());
    try std.testing.expectEqual(@as(u16, 8787), holderOf(io, root).port);

    // Released: the next taker gets it, and its record replaces the old one.
    first_held = false;
    first.taken.release(io);
    var third = try take(io, root, 9999, "0.0.0.0");
    try std.testing.expect(third == .taken);
    var third_held = true;
    defer if (third_held) third.taken.release(io);
    try std.testing.expectEqual(@as(u16, 9999), holderOf(io, root).port);
    third_held = false;
    third.taken.release(io);
    // Nothing is left behind: a released dir has no lock file.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, root ++ "/" ++ FILE_NAME, .{}));
}

test "a lock file left by a process that no longer exists does not block the next start" {
    const gpa = std.testing.allocator;
    const root = "zig-datalock-stale-tmp";
    var f: Fixture = undefined;
    f.init(gpa, root);
    defer f.deinit(root);
    const io = f.threaded.io();

    // A crashed holder leaves its record and nothing else: no open handle, no flock.
    const DEAD_PID: u32 = 4_000_000_000; // above any pid either OS hands out
    try std.testing.expect(!pidAlive(DEAD_PID));
    try std.testing.expect(pidAlive(ownPid())); // the liveness check is not simply "no"
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/" ++ FILE_NAME, .data = "pid=4000000000\nport=1\nbind=0.0.0.0\n" });
    try std.testing.expectEqual(DEAD_PID, holderOf(io, root).pid);

    var lock = try take(io, root, 8787, "127.0.0.1");
    try std.testing.expect(lock == .taken);
    defer lock.taken.release(io);
    try std.testing.expectEqual(ownPid(), holderOf(io, root).pid);
    try std.testing.expectEqual(@as(u16, 8787), holderOf(io, root).port);
}

test "a record a holder has not written yet is read as unknown, and the refusal still comes" {
    // parseRecord on nothing, on garbage, and on a partial write: the gate never depends on the record.
    try std.testing.expect(!parseRecord("").known());
    try std.testing.expect(!parseRecord("not a record at all").known());
    const partial = parseRecord("pid=12\n");
    try std.testing.expectEqual(@as(u32, 12), partial.pid);
    try std.testing.expectEqual(@as(u16, 0), partial.port);
    try std.testing.expectEqualStrings("", partial.bindStr());
    const crlf = parseRecord("pid=12\r\nport=8787\r\nbind=0.0.0.0\r\n");
    try std.testing.expectEqual(@as(u16, 8787), crlf.port);
    try std.testing.expectEqualStrings("0.0.0.0", crlf.bindStr());
}

// ---- a real second process ----

const bounded = @import("../worker/bounded.zig");

const PROC_ROOT = "zig-datalock-proc-tmp";

/// Test-only: another process trying the holder's open on PROC_ROOT's lock file, the way a second veil would, and
/// saying what it got. Windows: .NET's File.Open for WRITE access, sharing everything itself, so the only thing that
/// can refuse it is the holder's share mode: this probe is sensitive to OUR exclusivity, not its own. POSIX: flock(1)
/// on the file, non-blocking. Prints TAKEN, HELD, or NOFLOCK where flock(1) is not installed (macOS).
fn proberArgv() []const []const u8 {
    if (is_windows) return &.{
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        "$p = Join-Path $PWD '" ++ PROC_ROOT ++ "\\" ++ FILE_NAME ++ "'; " ++
            "try { $f = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete); $f.Close(); 'TAKEN' } " ++
            "catch { 'HELD ' + $_.Exception.Message }",
    };
    return &.{
        "/bin/sh", "-c",
        "command -v flock >/dev/null 2>&1 || { echo NOFLOCK; exit 0; }; " ++
            "if flock -n -x " ++ PROC_ROOT ++ "/" ++ FILE_NAME ++ " -c true; then echo TAKEN; else echo HELD; fi",
    };
}

/// Test-only: another process HOLDING PROC_ROOT's lock file the holder's way, with a record naming itself on port
/// 4242, until PROC_ROOT/stop appears (or 30 s pass). Its pid is the shell's own.
fn holderArgv() []const []const u8 {
    if (is_windows) return &.{
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        "$p = Join-Path $PWD '" ++ PROC_ROOT ++ "\\" ++ FILE_NAME ++ "'; $stop = Join-Path $PWD '" ++ PROC_ROOT ++ "\\stop'; " ++
            "$f = [IO.File]::Open($p, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read); " ++
            "$b = [Text.Encoding]::ASCII.GetBytes(\"pid=$PID`nport=4242`nbind=127.0.0.1`n\"); $f.Write($b, 0, $b.Length); $f.Flush(); " ++
            "$i = 0; while (-not (Test-Path $stop) -and $i -lt 600) { Start-Sleep -Milliseconds 50; $i++ }; $f.Close()",
    };
    return &.{
        "/bin/sh", "-c",
        "command -v flock >/dev/null 2>&1 || exit 7; exec 9>" ++ PROC_ROOT ++ "/" ++ FILE_NAME ++ "; flock -x 9 || exit 8; " ++
            "printf 'pid=%s\\nport=4242\\nbind=127.0.0.1\\n' $$ >&9; " ++
            "i=0; while [ ! -e " ++ PROC_ROOT ++ "/stop ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done",
    };
}

/// Test-only: run the prober and return its one word. Skips where it cannot run (no PowerShell, no flock).
fn probe(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    var r = bounded.run(gpa, io, .{ .argv = proberArgv(), .bound_ms = 60_000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return error.SkipZigTest;
    if (!r.finished()) return error.ProberDidNotFinish;
    const out = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (std.mem.startsWith(u8, out, "NOFLOCK")) return error.SkipZigTest;
    if (std.mem.startsWith(u8, out, "TAKEN")) return "TAKEN";
    if (std.mem.startsWith(u8, out, "HELD")) return "HELD";
    std.debug.print("\nprober printed neither verdict: stdout={s} stderr={s}\n", .{ r.stdout, r.stderr });
    return error.ProberSaidNothing;
}

const winproc_test = if (is_windows) struct {
    extern "kernel32" fn GetProcessId(h: std.os.windows.HANDLE) callconv(.winapi) u32;
} else struct {};

test "a second PROCESS cannot take a data dir this one serves, and takes it once this one lets go (real shell)" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    f.init(gpa, PROC_ROOT);
    defer f.deinit(PROC_ROOT);
    const io = f.threaded.io();

    var lock = try take(io, PROC_ROOT, 8787, "127.0.0.1");
    try std.testing.expect(lock == .taken);
    var held = true;
    defer if (held) lock.taken.release(io); // a failed assertion must not leave the dir held for the next test
    try std.testing.expectEqualStrings("HELD", try probe(gpa, io));
    held = false;
    lock.taken.release(io);
    try std.testing.expectEqualStrings("TAKEN", try probe(gpa, io));
}

test "a data dir another PROCESS serves is reported held with that process's pid and port, and free again once it exits (real shell)" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    f.init(gpa, PROC_ROOT);
    defer f.deinit(PROC_ROOT);
    const io = f.threaded.io();
    if (!is_windows) {
        // flock(1) is util-linux: present on Linux, absent on macOS. The prober says so without side effects.
        _ = try probe(gpa, io); // skips on NOFLOCK
    }

    var child = std.process.spawn(io, .{ .argv = holderArgv(), .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch return error.SkipZigTest;
    const child_pid: u32 = if (is_windows) winproc_test.GetProcessId(child.id.?) else @intCast(child.id.?);
    var stopped = false;
    defer if (!stopped) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = PROC_ROOT ++ "/stop", .data = "" }) catch {};
        _ = child.wait(io) catch {};
    };

    // The holder writes its record after locking; wait for the record, not for time.
    var polls: u32 = 0;
    while (holderOf(io, PROC_ROOT).port != 4242) : (polls += 1) {
        if (polls >= 600) return error.HolderNeverWroteItsRecord; // 30 s: a shell that cannot start is a failure, not a pass
        sleepMs(io, 50);
    }

    const refused = try take(io, PROC_ROOT, 8787, "0.0.0.0");
    try std.testing.expect(refused == .held);
    try std.testing.expectEqual(child_pid, refused.held.pid);
    try std.testing.expectEqual(@as(u16, 4242), refused.held.port);
    try std.testing.expectEqualStrings("127.0.0.1", refused.held.bindStr());
    try std.testing.expect(pidAlive(child_pid));

    // The holder exits: the kernel releases its lock, and the dir is ours.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = PROC_ROOT ++ "/stop", .data = "" });
    _ = try child.wait(io);
    stopped = true;
    var mine = try take(io, PROC_ROOT, 8787, "0.0.0.0");
    try std.testing.expect(mine == .taken);
    defer mine.taken.release(io);
    try std.testing.expectEqual(ownPid(), holderOf(io, PROC_ROOT).pid);
}
