//! meshsync.zig — the desk's settings, shared with the user's other veils through their harness.
//!
//! The harness keeps small named values for the whole account (cloud/veil-web/veil-web.js, "SHARED SETTINGS"): the
//! last write of a name wins, and each carries the time the harness took it. This file is the desk's half, pure:
//! which of its settings travel and under what names, how one is written as text and read back, and the decision
//! made for each name on a pass (take the harness's, give this desk's, or leave it). The poller does the calls
//! (GET and POST /api/v1/harness/settings on the server) and keeps what this desk last agreed with the harness in
//! {data}/.veil-desk/mesh-sync.json. No I/O here.
//!
//! WHAT TRAVELS: the chat model (and the thinking and prompting models of a split trio), the Cloudflare-default
//! choice, Agent Garrett on or off, speed mode, where the chat's brain runs, fast reasoning, the tool map, Clef, the
//! theme, and the reading settings (dyslexia face, text size, bold, narrator).
//! WHAT STAYS ON THE MACHINE: the server target (port, host), the data folder, every key and token (they live in
//! the operating system's secret store), the shell-approval bypass, the browser-window choice and the pane sizes.

const std = @import("std");
const store_mod = @import("store.zig");
const Settings = store_mod.Settings;
const RoleCfg = store_mod.RoleCfg;

pub const VALUE_MAX = 400; // the longest value this desk writes (a role: two numbers, a 192-byte base, a 96-byte model)
pub const NAME_MAX = 24;

/// The names, as the harness keeps them. "desk." marks them as a desktop veil's.
pub const KEYS = [_][]const u8{
    "desk.chat",       "desk.think",   "desk.prompt",    "desk.cf_default", "desk.garrett",
    "desk.speed",      "desk.srv_brain", "desk.fast",    "desk.tool_map",   "desk.clef",
    "desk.theme",      "desk.dyslexia", "desk.font_scale", "desk.font_bold", "desk.narrator",
};

fn flag(buf: []u8, on: bool) []const u8 {
    buf[0] = if (on) '1' else '0';
    return buf[0..1];
}

/// A base or a model as one field of a `|`-separated value: neither holds a `|` or a line break in practice, and
/// one that did would be read back short, so it is refused here (the value is then not written at all).
fn clean(s: []const u8) bool {
    for (s) |c| if (c == '|' or c < 0x20) return false;
    return true;
}

fn roleText(buf: []u8, r: *const RoleCfg) ?[]const u8 {
    if (!clean(r.baseStr()) or !clean(r.modelStr())) return null;
    return std.fmt.bufPrint(buf, "{d}|{d}|{d}|{s}|{s}", .{ @intFromBool(r.set), r.kind, r.byok, r.baseStr(), r.modelStr() }) catch null;
}

/// This desk's value for one name, as text. Null for a name that is not one of KEYS, or a value that cannot be
/// written faithfully.
pub fn localValue(s: *const Settings, key: []const u8, buf: []u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (buf.len < VALUE_MAX) return null;
    if (eq(u8, key, "desk.chat")) {
        const base = s.chat_base[0..s.chat_base_len];
        const model = s.chat_model[0..s.chat_model_len];
        if (!clean(base) or !clean(model)) return null;
        return std.fmt.bufPrint(buf, "{d}|{d}|{d}|{s}|{s}", .{ s.chat_kind, s.chat_byok, @intFromBool(s.chat_unified), base, model }) catch null;
    }
    if (eq(u8, key, "desk.think")) return roleText(buf, &s.chat_think);
    if (eq(u8, key, "desk.prompt")) return roleText(buf, &s.chat_prompt);
    if (eq(u8, key, "desk.cf_default")) return std.fmt.bufPrint(buf, "{d}", .{s.cf_default}) catch null;
    if (eq(u8, key, "desk.garrett")) return flag(buf, s.use_garrett);
    if (eq(u8, key, "desk.speed")) return flag(buf, s.speed_mode);
    if (eq(u8, key, "desk.srv_brain")) return flag(buf, s.server_chat);
    if (eq(u8, key, "desk.fast")) return flag(buf, s.fast_reasoning);
    if (eq(u8, key, "desk.tool_map")) return flag(buf, s.tool_map);
    if (eq(u8, key, "desk.clef")) return flag(buf, s.clef);
    if (eq(u8, key, "desk.theme")) {
        const id = s.theme_id[0..s.theme_id_len];
        if (id.len == 0 or !clean(id)) return null; // a legacy numbered theme has no id to give yet
        @memcpy(buf[0..id.len], id);
        return buf[0..id.len];
    }
    if (eq(u8, key, "desk.dyslexia")) return flag(buf, s.dyslexia);
    if (eq(u8, key, "desk.font_scale")) return std.fmt.bufPrint(buf, "{d}", .{s.font_scale}) catch null;
    if (eq(u8, key, "desk.font_bold")) return flag(buf, s.font_bold);
    if (eq(u8, key, "desk.narrator")) return flag(buf, s.narrator);
    return null;
}

fn asFlag(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "0")) return false;
    return null;
}

fn put(dst: []u8, len: anytype, src: []const u8) bool {
    if (src.len > dst.len) return false;
    @memset(dst, 0);
    @memcpy(dst[0..src.len], src);
    len.* = @intCast(src.len);
    return true;
}

const Parts = struct { a: u8, b: u8, c: u8, base: []const u8, model: []const u8 };

/// "<n>|<n>|<n>|<base>|<model>", every part checked.
fn parts(v: []const u8) ?Parts {
    var it = std.mem.splitScalar(u8, v, '|');
    const a = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const c = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const base = it.next() orelse return null;
    const model = it.next() orelse return null;
    if (it.next() != null or base.len > 192 or model.len > 96) return null;
    for (v) |ch| if (ch < 0x20) return null;
    return .{ .a = a, .b = b, .c = c, .base = base, .model = model };
}

fn applyRole(r: *RoleCfg, v: []const u8) bool {
    const p = parts(v) orelse return false;
    if (p.a > 1 or p.b > 2) return false;
    r.set = p.a == 1;
    r.kind = p.b;
    r.byok = p.c;
    _ = put(&r.base, &r.base_len, p.base);
    _ = put(&r.model, &r.model_len, p.model);
    return true;
}

/// Take one value from the harness into this desk's settings. False, with nothing changed, for a name that is not
/// one of KEYS or a value this desk could not have written (another veil's mistake must not reach the settings).
pub fn apply(s: *Settings, key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "desk.chat")) {
        const p = parts(v) orelse return false;
        if (p.a > 2 or p.c > 1) return false;
        s.chat_kind = p.a;
        s.chat_byok = p.b;
        s.chat_unified = p.c == 1;
        _ = put(&s.chat_base, &s.chat_base_len, p.base);
        _ = put(&s.chat_model, &s.chat_model_len, p.model);
        return true;
    }
    if (eq(u8, key, "desk.think")) return applyRole(&s.chat_think, v);
    if (eq(u8, key, "desk.prompt")) return applyRole(&s.chat_prompt, v);
    if (eq(u8, key, "desk.cf_default")) {
        const n = std.fmt.parseInt(u8, v, 10) catch return false;
        if (n > 2) return false;
        s.cf_default = n;
        return true;
    }
    if (eq(u8, key, "desk.theme")) {
        if (v.len == 0 or v.len > s.theme_id.len) return false;
        for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
        return put(&s.theme_id, &s.theme_id_len, v);
    }
    if (eq(u8, key, "desk.font_scale")) {
        const n = std.fmt.parseInt(u8, v, 10) catch return false;
        if (n != 90 and n != 100 and n != 112 and n != 125) return false;
        s.font_scale = n;
        return true;
    }
    const on = asFlag(v) orelse return false;
    if (eq(u8, key, "desk.garrett")) s.use_garrett = on else if (eq(u8, key, "desk.speed")) s.speed_mode = on else if (eq(u8, key, "desk.srv_brain")) s.server_chat = on else if (eq(u8, key, "desk.fast")) s.fast_reasoning = on else if (eq(u8, key, "desk.tool_map")) s.tool_map = on else if (eq(u8, key, "desk.clef")) s.clef = on else if (eq(u8, key, "desk.dyslexia")) s.dyslexia = on else if (eq(u8, key, "desk.font_bold")) s.font_bold = on else if (eq(u8, key, "desk.narrator")) s.narrator = on else return false;
    return true;
}

/// What a pass does with one name.
pub const Action = enum { none, take, give };

/// The decision for one name. `local`: this desk's value now. `synced`/`synced_at`: what this desk and the harness
/// last agreed on, and the harness's time for it (0 = never). `remote`/`remote_at`: what the harness holds now
/// (null = nothing).
///   - the harness has a newer write than the one agreed on: TAKE it (when both sides changed, the harness wins:
///     its copy is the one every other veil already took).
///   - otherwise, this desk's value differs from the agreed one (or nothing was ever agreed): GIVE it.
pub fn decide(local: []const u8, synced: ?[]const u8, synced_at: i64, remote: ?[]const u8, remote_at: i64) Action {
    if (remote) |r| {
        if (remote_at > synced_at) return if (std.mem.eql(u8, r, local)) .none else .take;
        if (synced) |sv| return if (std.mem.eql(u8, sv, local)) .none else .give;
        return .give;
    }
    return .give; // the harness has nothing under this name: this desk is the first to say
}

/// One name as the harness or the sync file holds it.
pub const Entry = struct {
    key: [NAME_MAX]u8 = [_]u8{0} ** NAME_MAX,
    key_len: u8 = 0,
    v: [VALUE_MAX]u8 = [_]u8{0} ** VALUE_MAX,
    v_len: u16 = 0,
    at: i64 = 0,

    pub fn keyStr(e: *const Entry) []const u8 {
        return e.key[0..e.key_len];
    }
    pub fn vStr(e: *const Entry) []const u8 {
        return e.v[0..e.v_len];
    }
};

pub const Table = struct {
    rows: [KEYS.len]Entry = [_]Entry{.{}} ** KEYS.len,
    n: usize = 0,

    pub fn find(t: *const Table, key: []const u8) ?*const Entry {
        for (t.rows[0..t.n]) |*e| if (std.mem.eql(u8, e.keyStr(), key)) return e;
        return null;
    }

    pub fn set(t: *Table, key: []const u8, v: []const u8, at: i64) void {
        if (key.len > NAME_MAX or v.len > VALUE_MAX) return;
        var slot: ?*Entry = null;
        for (t.rows[0..t.n]) |*e| if (std.mem.eql(u8, e.keyStr(), key)) {
            slot = e;
        };
        if (slot == null) {
            if (t.n == t.rows.len) return;
            slot = &t.rows[t.n];
            t.n += 1;
        }
        const e = slot.?;
        e.* = .{ .at = at };
        @memcpy(e.key[0..key.len], key);
        e.key_len = @intCast(key.len);
        @memcpy(e.v[0..v.len], v);
        e.v_len = @intCast(v.len);
    }
};

fn isKey(name: []const u8) bool {
    for (KEYS) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Read `{"settings": {name: {v, at}}}` (the harness's answer, and the sync file's own shape) into a table. Only
/// this desk's names with a text value are kept; a number or true/false another veil wrote under one of them is not
/// something this desk writes, and is left out. Null for anything that is not that shape.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) ?Table {
    const p = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer p.deinit();
    if (p.value != .object) return null;
    const all = p.value.object.get("settings") orelse return null;
    if (all != .object) return null;
    var t: Table = .{};
    var it = all.object.iterator();
    while (it.next()) |kv| {
        if (!isKey(kv.key_ptr.*) or kv.value_ptr.* != .object) continue;
        const v = kv.value_ptr.object.get("v") orelse continue;
        const at = kv.value_ptr.object.get("at") orelse continue;
        if (v != .string or at != .integer) continue;
        t.set(kv.key_ptr.*, v.string, at.integer);
    }
    return t;
}

/// A table as `{"settings": {name: {v, at}}}`: the sync file.
pub fn write(gpa: std.mem.Allocator, t: *const Table) ?[]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return null;
    js.objectField("settings") catch return null;
    js.beginObject() catch return null;
    for (t.rows[0..t.n]) |*e| {
        js.objectField(e.keyStr()) catch return null;
        js.write(.{ .v = e.vStr(), .at = e.at }) catch return null;
    }
    js.endObject() catch return null;
    js.endObject() catch return null;
    return out.toOwnedSlice() catch null;
}

/// `{"set": {name: value, ...}}` for the names in `give`: the body of POST /api/v1/harness/settings.
pub fn giveBody(gpa: std.mem.Allocator, give: *const Table) ?[]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return null;
    js.objectField("set") catch return null;
    js.beginObject() catch return null;
    for (give.rows[0..give.n]) |*e| {
        js.objectField(e.keyStr()) catch return null;
        js.write(e.vStr()) catch return null;
    }
    js.endObject() catch return null;
    js.endObject() catch return null;
    return out.toOwnedSlice() catch null;
}

// ---------------------------------------------------------------------------
const tt = std.testing;

test "every shared setting is written as text and read back to the same settings; machine-local ones never travel" {
    var a: Settings = .{};
    a.chat_kind = 1;
    a.chat_byok = 3;
    a.chat_unified = false;
    _ = put(&a.chat_base, &a.chat_base_len, "https://example.com/v1");
    _ = put(&a.chat_model, &a.chat_model_len, "@cf/x/y");
    a.chat_think = .{ .set = true, .kind = 2, .byok = 0 };
    _ = put(&a.chat_think.base, &a.chat_think.base_len, "https://think.example.com/v1");
    _ = put(&a.chat_think.model, &a.chat_think.model_len, "think-1");
    a.cf_default = 2;
    a.use_garrett = true;
    a.speed_mode = false;
    a.server_chat = false;
    a.fast_reasoning = true;
    a.tool_map = true;
    a.clef = false;
    _ = put(&a.theme_id, &a.theme_id_len, "matrix");
    a.dyslexia = true;
    a.font_scale = 125;
    a.font_bold = true;
    a.narrator = true;
    a.port = 9999; // machine-local: must not travel
    a.shell_always_allow = true;
    a.browser_headful = true;

    var b: Settings = .{};
    var buf: [VALUE_MAX]u8 = undefined;
    for (KEYS) |k| try tt.expect(apply(&b, k, localValue(&a, k, &buf).?));
    for (KEYS) |k| {
        var b2: [VALUE_MAX]u8 = undefined;
        try tt.expectEqualStrings(localValue(&a, k, &buf).?, localValue(&b, k, &b2).?);
    }
    try tt.expectEqualStrings("@cf/x/y", b.chat_model[0..b.chat_model_len]);
    try tt.expect(b.chat_think.set and b.chat_think.kind == 2);
    try tt.expectEqual(@as(u16, 8787), b.port);
    try tt.expect(!b.shell_always_allow and !b.browser_headful);
    for (KEYS) |k| try tt.expect(k.len <= NAME_MAX and std.mem.startsWith(u8, k, "desk."));
}

test "a value this desk could not have written changes nothing" {
    var s: Settings = .{};
    const before = s;
    for ([_][2][]const u8{
        .{ "desk.chat", "9|0|1||m" }, .{ "desk.chat", "1|0|1|only-four" }, .{ "desk.chat", "1|0|1|a|b|c" }, .{ "desk.chat", "x|0|1||m" },
        .{ "desk.think", "2|0|0||m" }, .{ "desk.cf_default", "3" },         .{ "desk.font_scale", "200" },    .{ "desk.theme", "../x" },
        .{ "desk.theme", "" },         .{ "desk.clef", "yes" },             .{ "desk.port", "1" },            .{ "web.model", "@cf/x/y" },
    }) |c| try tt.expect(!apply(&s, c[0], c[1]));
    try tt.expectEqual(before.chat_kind, s.chat_kind);
    try tt.expectEqual(before.cf_default, s.cf_default);
    try tt.expectEqual(before.font_scale, s.font_scale);
    try tt.expectEqual(before.clef, s.clef);
    // a model or a base holding the separator is not written at all
    var buf: [VALUE_MAX]u8 = undefined;
    _ = put(&s.chat_model, &s.chat_model_len, "odd|model");
    try tt.expect(localValue(&s, "desk.chat", &buf) == null);
    try tt.expect(localValue(&s, "desk.theme", &buf) == null); // no theme id yet
    try tt.expect(localValue(&s, "desk.port", &buf) == null);
}

test "the decision: the first desk gives, a second desk takes, a local change is given, and the harness wins a tie" {
    // nothing on the harness: this desk says first
    try tt.expectEqual(Action.give, decide("1", null, 0, null, 0));
    // a second desk, never synced, finds the account's value: it takes it
    try tt.expectEqual(Action.take, decide("0", null, 0, "1", 50));
    // ... unless it already has that value
    try tt.expectEqual(Action.none, decide("1", null, 0, "1", 50));
    // agreed, and nobody changed anything
    try tt.expectEqual(Action.none, decide("1", "1", 50, "1", 50));
    // the owner changed it here
    try tt.expectEqual(Action.give, decide("0", "1", 50, "1", 50));
    // another veil changed it
    try tt.expectEqual(Action.take, decide("1", "1", 50, "0", 60));
    // both changed: the harness's is the one the other veils already have
    try tt.expectEqual(Action.take, decide("2", "1", 50, "0", 60));
    // the harness lost it (settings cleared): given again
    try tt.expectEqual(Action.give, decide("1", "1", 50, null, 0));
}

test "the harness's answer and the sync file are one shape; other veils' names and non-text values are left out" {
    const gpa = tt.allocator;
    const body = "{\"ok\":true,\"now\":9,\"settings\":{\"desk.clef\":{\"v\":\"1\",\"at\":50},\"desk.theme\":{\"v\":\"matrix\",\"at\":61},\"web.model\":{\"v\":\"@cf/x/y\",\"at\":70},\"desk.speed\":{\"v\":true,\"at\":71},\"desk.fast\":\"1\"},\"max\":128}";
    const t = parse(gpa, body).?;
    try tt.expectEqual(@as(usize, 2), t.n);
    try tt.expectEqualStrings("matrix", t.find("desk.theme").?.vStr());
    try tt.expectEqual(@as(i64, 50), t.find("desk.clef").?.at);
    try tt.expect(t.find("web.model") == null and t.find("desk.speed") == null and t.find("desk.fast") == null);

    const file = write(gpa, &t).?;
    defer gpa.free(file);
    const back = parse(gpa, file).?;
    try tt.expectEqual(@as(usize, 2), back.n);
    try tt.expectEqual(@as(i64, 61), back.find("desk.theme").?.at);

    var give: Table = .{};
    give.set("desk.clef", "0", 0);
    give.set("desk.chat", "1|0|1||@cf/x/\"y\"", 0);
    const sent = giveBody(gpa, &give).?;
    defer gpa.free(sent);
    try tt.expectEqualStrings("{\"set\":{\"desk.clef\":\"0\",\"desk.chat\":\"1|0|1||@cf/x/\\\"y\\\"\"}}", sent);
    try tt.expect(parse(gpa, "[]") == null and parse(gpa, "{\"ok\":false}") == null and parse(gpa, "nope") == null);
}
