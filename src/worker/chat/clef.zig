//! CLEF MODE: yes/no decisions of a chat turn, answered by Cloudflare's Clef decision model instead of a chat model.
//!
//! Clef takes a `state` and a set of questions and returns a PROBABILITY per question; it writes no text. One POST
//! to `{api_root}/accounts/{account}/ai/run/@cf/cloudflare/clef-flash` carries up to MAX_QUESTIONS questions, and
//! only input tokens are billed. This file asks `noul` (yes/no) questions only: each answer is the probability that
//! the answer is yes.
//!
//! The engine (chat/engine.zig) decides what to do with a probability. Every failure here is null, and the engine
//! then makes the decision the way it did before clef mode: a clef call can only save a model call, never lose a
//! decision.
//!
//! The call goes through cf_oauth.curl, the one Cloudflare transport, so the bearer rides curl's stdin.

const std = @import("std");
const cf_oauth = @import("../../config/cf_oauth.zig");
const llm = @import("../llm.zig");

/// The Workers AI model id (the URL's tail) and the name the request body carries for it.
pub const MODEL = "@cf/cloudflare/clef-flash";
const WIRE_MODEL = "clef-flash";

/// Cloudflare accepts 1 to 64 questions per request.
pub const MAX_QUESTIONS: usize = 64;

/// A decision is small and the turn is waiting on it: a slow answer is a failed one, and the engine falls back.
const MAX_TIME_S: u32 = 20;

pub const Usage = struct { in: u64 = 0, out: u64 = 0 };

/// Where one turn's clef calls go, and with whose authority. Borrowed from the turn: nothing here is owned.
pub const Target = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// A body too big for curl's stdin config is written here for the call's life (cf_oauth.curl).
    scratch: []const u8,
    api_root: []const u8,
    account: []const u8,
    token: []const u8,
};

/// Ask every question in `questions` about `state`. On success `probs[i]` is the probability that question i's
/// answer is yes, and the call's token usage is returned. Null on any failure, with `probs` unspecified.
pub fn ask(t: Target, state: []const u8, questions: []const []const u8, probs: []f64) ?Usage {
    if (questions.len == 0 or questions.len > MAX_QUESTIONS or probs.len < questions.len) return null;
    if (t.account.len == 0 or t.token.len == 0) return null;
    const gpa = t.gpa;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    buildBody(gpa, &body, state, questions) catch return null;
    const url = std.fmt.allocPrint(gpa, "{s}/accounts/{s}/ai/run/" ++ MODEL, .{ t.api_root, t.account }) catch return null;
    defer gpa.free(url);
    const raw = cf_oauth.curl(.{ .gpa = gpa, .io = t.io, .scratch = t.scratch, .body_prefix = ".clef-body-", .max_time_s = MAX_TIME_S, .stdout_limit = 256 << 10 }, "POST", url, body.items, t.token, "application/json") orelse return null;
    defer gpa.free(raw);
    return parse(gpa, raw, questions.len, probs);
}

/// The request body: question i is keyed `q{i}`, and its answer comes back under the same key.
pub fn buildBody(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), state: []const u8, questions: []const []const u8) !void {
    try out.appendSlice(gpa, "{\"model\":\"" ++ WIRE_MODEL ++ "\",\"state\":");
    try llm.jstr(gpa, out, state);
    try out.appendSlice(gpa, ",\"questions\":{");
    for (questions, 0..) |q, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "\"q{d}\":{{\"type\":\"noul\",\"instructions\":", .{i});
        try llm.jstr(gpa, out, q);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "}}");
}

/// Read `n` noul answers (`q0`..) out of a reply. The reply is Cloudflare's `{success, errors, result}` envelope
/// around `{model, answers, usage}`; a bare `{model, answers, usage}` is read too. Null unless EVERY question has a
/// probability in [0, 1]: a partial answer is no answer.
pub fn parse(gpa: std.mem.Allocator, raw: []const u8, n: usize, probs: []f64) ?Usage {
    if (n == 0 or probs.len < n) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return null;
    defer parsed.deinit();
    var root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (root.get("success")) |s| {
        if (s != .bool or !s.bool) return null;
    }
    if (root.get("result")) |r| {
        root = switch (r) {
            .object => |o| o,
            else => return null,
        };
    }
    const answers = switch (root.get("answers") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    for (0..n) |i| {
        var kb: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "q{d}", .{i}) catch return null;
        const ans = switch (answers.get(key) orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const p: f64 = switch (ans.get("noul") orelse return null) {
            .float => |f| f,
            .integer => |v| @floatFromInt(v),
            else => return null,
        };
        if (!(p >= 0.0 and p <= 1.0)) return null;
        probs[i] = p;
    }
    var usage: Usage = .{};
    if (root.get("usage")) |u| {
        if (u == .object) {
            usage.in = tokenCount(u.object.get("input_tokens"));
            usage.out = tokenCount(u.object.get("output_tokens"));
        }
    }
    return usage;
}

fn tokenCount(v: ?std.json.Value) u64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

test "clef body: one noul question per instruction, keyed q0.., text escaped" {
    const gpa = std.testing.allocator;
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    try buildBody(gpa, &b, "line one\n\"two\"", &.{ "Is it done?", "Is it \"safe\"?" });
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, b.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("clef-flash", o.get("model").?.string);
    try std.testing.expectEqualStrings("line one\n\"two\"", o.get("state").?.string);
    const qs = o.get("questions").?.object;
    try std.testing.expectEqual(@as(usize, 2), qs.count());
    try std.testing.expectEqualStrings("noul", qs.get("q0").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("Is it done?", qs.get("q0").?.object.get("instructions").?.string);
    try std.testing.expectEqualStrings("Is it \"safe\"?", qs.get("q1").?.object.get("instructions").?.string);
}

test "clef reply: enveloped and bare answers both read, with usage" {
    const gpa = std.testing.allocator;
    var p: [2]f64 = undefined;
    const env =
        \\{"success":true,"errors":[],"result":{"model":"clef-flash","answers":{"q0":{"type":"noul","noul":0.93},"q1":{"type":"noul","noul":0}},"usage":{"input_tokens":412,"output_tokens":0}}}
    ;
    const u = parse(gpa, env, 2, &p).?;
    try std.testing.expectEqual(@as(f64, 0.93), p[0]);
    try std.testing.expectEqual(@as(f64, 0.0), p[1]);
    try std.testing.expectEqual(@as(u64, 412), u.in);
    try std.testing.expectEqual(@as(u64, 0), u.out);
    const bare =
        \\{"model":"clef-flash","answers":{"q0":{"type":"noul","noul":1}},"usage":{"input_tokens":7,"output_tokens":0}}
    ;
    try std.testing.expect(parse(gpa, bare, 1, &p) != null);
    try std.testing.expectEqual(@as(f64, 1.0), p[0]);
}

test "clef reply: a failure, a missing answer, a wrong type or an out-of-range probability is no answer" {
    const gpa = std.testing.allocator;
    var p: [2]f64 = undefined;
    const bad = [_][]const u8{
        "",
        "not json",
        "[]",
        \\{"success":false,"errors":[{"code":5007,"message":"No such model"}],"result":null}
        ,
        \\{"success":true,"result":{"answers":{"q0":{"type":"noul","noul":0.5}}}}
        ,
        \\{"success":true,"result":{"answers":{"q0":{"type":"noul","noul":0.5},"q1":{"type":"choice","choice":"a"}}}}
        ,
        \\{"success":true,"result":{"answers":{"q0":{"type":"noul","noul":0.5},"q1":{"type":"noul","noul":1.5}}}}
        ,
        \\{"success":true,"result":{"answers":{"q0":{"type":"noul","noul":0.5},"q1":{"type":"noul","noul":"0.9"}}}}
        ,
    };
    for (bad) |raw| try std.testing.expect(parse(gpa, raw, 2, &p) == null);
}

test "clef ask: refuses before any call without questions, an account or a token" {
    const gpa = std.testing.allocator;
    var p: [1]f64 = undefined;
    const t: Target = .{ .gpa = gpa, .io = std.testing.io, .scratch = ".", .api_root = "http://127.0.0.1:1", .account = "", .token = "" };
    try std.testing.expect(ask(t, "s", &.{"q"}, &p) == null);
    var full = t;
    full.account = "acct";
    full.token = "tok";
    try std.testing.expect(ask(full, "s", &.{}, &p) == null);
}
