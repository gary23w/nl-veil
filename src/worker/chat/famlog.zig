//! famlog.zig — THE FAMILY LEDGER (NL_FAMILY_MSG, default OFF): `convs/<primary>/family.jsonl`, the one typed,
//! append-only record of what the conversations of a family say to each other.
//!
//!   {"seq":N,"ts":S,"kind":"<kind>","from":"<conv>","from_epoch":"<8 hex>","to":"<conv>","to_epoch":"<8 hex>",
//!    "text":"...","re":M,"status":"<word>"}
//!
//! kinds: open (the primary opened a sub-chat on a goal), steer and question (the primary to a sub-chat), result and
//! answer (a sub-chat to the primary; an answer names the question's seq in `re`), done (written by the ENGINE when a
//! sub-chat's turn ends: its status and the answer it settled on, so the primary gets a branch's answer without any
//! model having to remember to send it). `re` rides only on an answer and `status` only on a done.
//!
//! The EPOCHS (family.memberEpoch) name which conversation held a slot when the record was written: a sub-chat deleted
//! and opened again under the same id starts with a new epoch, and readers drop a record whose sub-chat epoch is not the
//! slot's current one, so a new sub-chat never inherits its predecessor's questions, steers or reports. An epoch the
//! writer could not read is left out (an open record is written before the new sub-chat has its first line).
//!
//! ONE writer, in this process, under one mutex: the seq of the next record is read from the file's last record and
//! the line appended while the mutex is held, so seqs never repeat or go back. (A data dir has one server: the data dir
//! lock.) A file left without its final '\n' (a write cut short) gets one before the next record, so that record is a
//! whole line of its own. Readers (family.zig readLog) read whole lines only. Nothing here touches neuron-db: the ledger
//! is a file of its family's own, never a memory scope.

const std = @import("std");
const http = @import("../../gateway/http.zig");
const family = @import("family.zig"); // the ledger's reader: its file name is defined there, once

pub const FILE = family.LOG_FILE;
/// The most of one record's text the ledger keeps (clipped on a character). A starting bound, not a measurement.
pub const TEXT_MAX: usize = 4096;
/// How much of the file's end is read to find the last seq: more than any one record can be. jstr writes a control
/// byte as a 6-byte \u00XX, so a record's text can take six times TEXT_MAX on the line; the ids, epochs, numbers and
/// status word fit the 1 KB beside it.
const TAIL_BYTES: usize = 6 * TEXT_MAX + 1024;
const MARK = "{\"seq\":";

pub const Kind = enum { open, steer, question, result, answer, done };

pub const Rec = struct {
    kind: Kind,
    from: []const u8,
    to: []const u8,
    text: []const u8,
    /// an answer's question
    re: u64 = 0,
    /// a done's status word
    status: []const u8 = "",
    /// the sender's and the receiver's epochs when the record was written ("" when not known)
    from_epoch: []const u8 = "",
    to_epoch: []const u8 = "",
};

var mtx: std.Io.Mutex = .init;

/// Append `rec` to `<primary_dir>/family.jsonl` with the next seq and `ts` (seconds). Returns the seq, or 0 when
/// nothing was written.
pub fn append(gpa: std.mem.Allocator, io: std.Io, primary_dir: []const u8, rec: Rec, ts: i64) u64 {
    const path = std.fmt.allocPrint(gpa, "{s}/" ++ FILE, .{primary_dir}) catch return 0;
    defer gpa.free(path);
    mtx.lockUncancelable(io);
    defer mtx.unlock(io);
    const tail = lastSeq(gpa, io, path);
    const seq = tail.seq + 1;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    // a line a cut-short write left open is closed first: the new record must not run on into it
    if (tail.open) line.append(gpa, '\n') catch return 0;
    recLine(gpa, &line, seq, ts, rec) catch return 0;
    http.appendFile(io, gpa, path, line.items) catch return 0;
    return seq;
}

/// One record as its line, '\n' included.
pub fn recLine(gpa: std.mem.Allocator, line: *std.ArrayListUnmanaged(u8), seq: u64, ts: i64, rec: Rec) !void {
    try line.print(gpa, "{{\"seq\":{d},\"ts\":{d},\"kind\":\"{s}\",\"from\":", .{ seq, ts, @tagName(rec.kind) });
    try http.jstr(gpa, line, rec.from);
    if (rec.from_epoch.len > 0) {
        try line.appendSlice(gpa, ",\"from_epoch\":");
        try http.jstr(gpa, line, rec.from_epoch);
    }
    try line.appendSlice(gpa, ",\"to\":");
    try http.jstr(gpa, line, rec.to);
    if (rec.to_epoch.len > 0) {
        try line.appendSlice(gpa, ",\"to_epoch\":");
        try http.jstr(gpa, line, rec.to_epoch);
    }
    try line.appendSlice(gpa, ",\"text\":");
    try http.jstr(gpa, line, clipChars(rec.text, TEXT_MAX));
    if (rec.re > 0) try line.print(gpa, ",\"re\":{d}", .{rec.re});
    if (rec.status.len > 0) {
        try line.appendSlice(gpa, ",\"status\":");
        try http.jstr(gpa, line, rec.status);
    }
    try line.appendSlice(gpa, "}\n");
}

/// The file's end as the next append needs it: the highest seq among its last records (0 when it has none or does
/// not exist), and whether its last line was left open (no final '\n').
const Tail = struct { seq: u64 = 0, open: bool = false };

fn lastSeq(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Tail {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .{};
    defer f.close(io);
    const size: usize = std.math.cast(usize, f.length(io) catch return .{}) orelse return .{};
    const want = @min(size, TAIL_BYTES);
    const buf = gpa.alloc(u8, want) catch return .{};
    defer gpa.free(buf);
    const got = f.readPositionalAll(io, buf, size - want) catch return .{};
    var out: Tail = .{ .open = got > 0 and buf[got - 1] != '\n' };
    var it = std.mem.splitScalar(u8, buf[0..got], '\n');
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, MARK)) continue;
        var i: usize = MARK.len;
        while (i < l.len and std.ascii.isDigit(l[i])) i += 1;
        const n = std.fmt.parseInt(u64, l[MARK.len..i], 10) catch continue;
        // a line cut short is still a record once its own seq is there: its seq is never handed out again
        out.seq = @max(out.seq, n);
    }
    return out;
}

/// `s` cut to at most `max` bytes on a character boundary.
fn clipChars(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

// ---- tests ----

const tt = std.testing;

test "the ledger: seqs from 1 that never repeat, one whole JSON line per record, a long text clipped on a character" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-famlog-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try tt.expectEqual(@as(u64, 1), append(gpa, io, dir, .{ .kind = .open, .from = "c42", .to = "c42__s1", .text = "Sound the channel." }, 100));
    try tt.expectEqual(@as(u64, 2), append(gpa, io, dir, .{ .kind = .question, .from = "c42", .to = "c42__s1", .text = "How \"deep\"?\nIn metres." }, 101));
    try tt.expectEqual(@as(u64, 3), append(gpa, io, dir, .{ .kind = .answer, .from = "c42__s1", .to = "c42", .text = "12 m", .re = 2 }, 102));
    var big: [TEXT_MAX + 10]u8 = undefined;
    @memset(&big, 'x');
    @memcpy(big[TEXT_MAX - 1 .. TEXT_MAX + 1], "\xc3\xa9"); // a two-byte character across the cut
    try tt.expectEqual(@as(u64, 4), append(gpa, io, dir, .{ .kind = .done, .from = "c42__s1", .to = "c42", .text = &big, .status = "finished" }, 103));
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/" ++ FILE, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) try tt.expect(try std.json.validate(gpa, l));
    try tt.expectEqual(@as(usize, 4), n);
    try tt.expect(std.mem.indexOf(u8, raw, "{\"seq\":3,\"ts\":102,\"kind\":\"answer\",\"from\":\"c42__s1\",\"to\":\"c42\",\"text\":\"12 m\",\"re\":2}\n") != null);
    try tt.expect(std.mem.indexOf(u8, raw, "\"text\":\"How \\\"deep\\\"?\\nIn metres.\"") != null);
    // the long text: clipped before the character it would have split, so the line is still valid UTF-8
    try tt.expect(std.unicode.utf8ValidateSlice(raw));
    try tt.expect(std.mem.indexOf(u8, raw, ",\"status\":\"finished\"}") != null);
}

test "the ledger's seq survives a record of control bytes and a write cut short, and epochs ride when known" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-famlog-tail-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // a done record whose text is nothing but ESC: jstr writes each as \u001b, six times TEXT_MAX on the line
    var esc: [TEXT_MAX]u8 = undefined;
    @memset(&esc, 0x1b);
    try tt.expectEqual(@as(u64, 1), append(gpa, io, dir, .{ .kind = .done, .from = "c42__s1", .to = "c42", .text = &esc, .status = "finished", .from_epoch = "0a1b2c3d" }, 100));
    // the next seq is read past that whole line, not restarted at 1
    try tt.expectEqual(@as(u64, 2), append(gpa, io, dir, .{ .kind = .question, .from = "c42", .to = "c42__s1", .text = "How deep?", .to_epoch = "0a1b2c3d" }, 101));
    // a write cut short: a record with no final '\n'
    try http.appendFile(io, gpa, dir ++ "/" ++ FILE, "{\"seq\":3,\"ts\":102,\"kind\":\"res");
    try tt.expectEqual(@as(u64, 4), append(gpa, io, dir, .{ .kind = .answer, .from = "c42__s1", .to = "c42", .text = "12 m", .re = 2 }, 103));
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/" ++ FILE, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    // the cut line was closed, and the new record is a whole line of its own
    try tt.expect(std.mem.indexOf(u8, raw, "\"kind\":\"res\n{\"seq\":4,\"ts\":103,\"kind\":\"answer\"") != null);
    try tt.expect(std.mem.endsWith(u8, raw, "\"text\":\"12 m\",\"re\":2}\n"));
    // epochs where the writer knew them, nothing where it did not
    try tt.expect(std.mem.indexOf(u8, raw, "{\"seq\":2,\"ts\":101,\"kind\":\"question\",\"from\":\"c42\",\"to\":\"c42__s1\",\"to_epoch\":\"0a1b2c3d\",\"text\":\"How deep?\"}\n") != null);
    try tt.expect(std.mem.indexOf(u8, raw, "\"from\":\"c42__s1\",\"from_epoch\":\"0a1b2c3d\",\"to\":\"c42\"") != null);
}
