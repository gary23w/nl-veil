const std = @import("std");
const http = @import("../gateway/http.zig");
const App = http.App;
const vault = @import("key_vault.zig");

pub const DASHBOARD = "https://agent.garrettstimpson.ca/dashboard";
pub const MCP_URL = "https://agent.garrettstimpson.ca/mcp";
const CONNECTION_FILE = "garrett_connection.sealed";
const SavedConnection = struct { version: u8 = 1, uid: u64, key: []const u8, tools: usize = 0, checked_at: i64 = 0 };
pub const Managed = struct { present: bool = false, creds: ?Creds = null, tools: usize = 0, checked_at: i64 = 0 };

pub fn validKey(key: []const u8) bool {
    if (key.len != 68 or !std.mem.startsWith(u8, key, "gtt_")) return false;
    for (key[4..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

fn connectionPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ CONNECTION_FILE, .{ app.data, uid }) catch null;
}

/// An explicit managed connection (including disconnect) overrides legacy derived
/// credentials. Corrupt or copied files fail closed instead of reviving an old key.
pub fn managedFor(app: *App, uid: u64, a: std.mem.Allocator) Managed {
    var pb: [700]u8 = undefined;
    const path = connectionPath(app, uid, &pb) orelse return .{ .present = true };
    const sealed = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(4096)) catch |err| return .{ .present = err != error.FileNotFound };
    defer a.free(sealed);
    const plain = vault.open(a, app.server_key, sealed) orelse return .{ .present = true };
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    const p = std.json.parseFromSlice(SavedConnection, a, plain, .{}) catch return .{ .present = true };
    defer p.deinit();
    const v = p.value;
    if (v.version != 1 or v.uid != uid or !validKey(v.key)) return .{ .present = true };
    const key = a.dupe(u8, v.key) catch return .{ .present = true };
    const url = a.dupe(u8, MCP_URL) catch {
        a.free(key);
        return .{ .present = true };
    };
    return .{ .present = true, .creds = .{ .mcp_url = url, .token = key }, .tools = v.tools, .checked_at = v.checked_at };
}

/// Atomic, user-bound AES-GCM storage. A blank key records a local disconnect;
/// it does not delete a cloud agent, rotate its keys, or affect its saved memory.
pub fn saveManaged(app: *App, uid: u64, key: []const u8, tools: usize) !void {
    if (key.len != 0 and !validKey(key)) return error.InvalidGarrettKey;
    const a = app.gpa;
    const plain = try std.json.Stringify.valueAlloc(a, SavedConnection{ .uid = uid, .key = key, .tools = tools, .checked_at = @intCast(@divTrunc(std.Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s)) }, .{});
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    const sealed = try vault.seal(a, app.io, app.server_key, plain);
    defer a.free(sealed);
    var db: [700]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, "{s}/u{d}", .{ app.data, uid });
    _ = try std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir);
    var pb: [700]u8 = undefined;
    const path = connectionPath(app, uid, &pb) orelse return error.NameTooLong;
    var random: [8]u8 = undefined;
    app.io.random(&random);
    const temporary = try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ path, std.fmt.bytesToHex(random, .lower) });
    defer a.free(temporary);
    defer std.Io.Dir.cwd().deleteFile(app.io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = temporary, .data = sealed });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, app.io);
}

pub fn connected(app: *App, uid: u64, a: std.mem.Allocator) bool {
    const c = credsFor(app, uid, a) orelse return false;
    defer a.free(c.mcp_url);
    defer {
        std.crypto.secureZero(u8, @constCast(c.token));
        a.free(c.token);
    }
    return true;
}

pub const SCRIPT = "veil-garrett";
pub const STATE_FILE = "cf_tots.json";
pub const MCP_LABEL = "veil-garrett-mcp"; // MCP_API_TOKEN: the bearer /mcp answers to
pub const ACCESS_LABEL = "veil-garrett-access"; // ACCESS_PASSWORD: the lock on its chat UI
pub const SESSION_LABEL = "veil-garrett-session"; // ACCESS_SESSION_SECRET

pub fn tokenWith(app: *App, label: []const u8, uid: u64, account: []const u8, gen: u32, out: *[64]u8) []const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var h = Hmac.init(&app.server_key);
    var nb: [48]u8 = undefined;
    h.update(label);
    h.update(std.fmt.bufPrint(&nb, "\x00u{d}\x00g{d}\x00", .{ uid, gen }) catch "");
    h.update(account);
    var mac: [Hmac.mac_length]u8 = undefined;
    h.final(&mac);
    out.* = std.fmt.bytesToHex(mac, .lower);
    return out;
}

pub const Creds = struct { mcp_url: []const u8, token: []const u8 };

const View = struct { account: []const u8 = "", token_gen: u32 = 0, garrett_url: []const u8 = "", garrett_account: []const u8 = "", garrett_gen: u32 = 0 };

pub fn credsFor(app: *App, uid: u64, a: std.mem.Allocator) ?Creds {
    const managed = managedFor(app, uid, a);
    if (managed.present) return managed.creds;
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(16 << 20)) catch return null;
    defer a.free(data);
    const parsed = std.json.parseFromSlice(View, a, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    if (v.garrett_url.len == 0) return null;
    const acct = if (v.garrett_account.len > 0) v.garrett_account else v.account;
    const gen = if (v.garrett_account.len > 0) v.garrett_gen else v.token_gen;
    var tb: [64]u8 = undefined;
    const token = a.dupe(u8, tokenWith(app, MCP_LABEL, uid, acct, gen, &tb)) catch return null;
    const mcp_url = std.fmt.allocPrint(a, "{s}/mcp", .{v.garrett_url}) catch {
        a.free(token);
        return null;
    };
    return .{ .mcp_url = mcp_url, .token = token };
}

const tt = std.testing;

test "dashboard keys survive reload and rotation, remain sealed, and cannot cross users" {
    const a = tt.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(a, io, "zig-garrett-dashboard-storage-tmp");
    defer ta.deinit();
    const first = "gtt_" ++ "a" ** 64;
    const second = "gtt_" ++ "b" ** 64;
    try saveManaged(&ta.app, 7, first, 166);
    const c = credsFor(&ta.app, 7, a).?;
    defer a.free(c.mcp_url);
    defer a.free(c.token);
    try tt.expectEqualStrings(MCP_URL, c.mcp_url);
    try tt.expectEqualStrings(first, c.token);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, "zig-garrett-dashboard-storage-tmp/u7/" ++ CONNECTION_FILE, a, .limited(4096));
    defer a.free(raw);
    try tt.expect(std.mem.indexOf(u8, raw, first) == null);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, "zig-garrett-dashboard-storage-tmp/u8", .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-garrett-dashboard-storage-tmp/u8/" ++ CONNECTION_FILE, .data = raw });
    try tt.expect(credsFor(&ta.app, 8, a) == null);
    try tt.expectError(error.InvalidGarrettKey, saveManaged(&ta.app, 7, "gtt_invalid", 0));
    try saveManaged(&ta.app, 7, second, 167);
    const rotated = managedFor(&ta.app, 7, a);
    defer a.free(rotated.creds.?.mcp_url);
    defer a.free(rotated.creds.?.token);
    try tt.expectEqualStrings(second, rotated.creds.?.token);
    try tt.expectEqual(@as(usize, 167), rotated.tools);
    try saveManaged(&ta.app, 7, "", 0);
    try tt.expect(credsFor(&ta.app, 7, a) == null);
}

test "managed disconnect or corruption cannot silently restore a legacy connection" {
    const a = tt.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(a, io, "zig-garrett-dashboard-legacy-tmp");
    defer ta.deinit();
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, "zig-garrett-dashboard-legacy-tmp/u7", .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-garrett-dashboard-legacy-tmp/u7/" ++ STATE_FILE, .data = "{\"account\":\"acct\",\"garrett_url\":\"https://veil-garrett.acme.workers.dev\"}" });
    try tt.expect(connected(&ta.app, 7, a));
    try saveManaged(&ta.app, 7, "", 0);
    try tt.expect(!connected(&ta.app, 7, a));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-garrett-dashboard-legacy-tmp/u7/" ++ CONNECTION_FILE, .data = "corrupt" });
    try tt.expect(!connected(&ta.app, 7, a));
}

test "the pair is read back from the state file and derived, never stored; no deployment is no pair" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfgarrett-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    const dir = root ++ "/u7";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    const path = dir ++ "/" ++ STATE_FILE;
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"account\":\"acct\",\"url\":\"https://veil-tots.acme.workers.dev\"}" });
    try tt.expect(credsFor(&ta.app, 7, gpa) == null);
    try tt.expect(credsFor(&ta.app, 8, gpa) == null);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"account\":\"\",\"token_gen\":3,\"garrett_url\":\"https://veil-garrett.acme.workers.dev\",\"garrett_account\":\"acct\",\"garrett_gen\":1}" });
    const c = credsFor(&ta.app, 7, gpa) orelse return error.TestUnexpectedResult;
    defer gpa.free(c.mcp_url);
    defer gpa.free(c.token);
    try tt.expectEqualStrings("https://veil-garrett.acme.workers.dev/mcp", c.mcp_url);
    var tb: [64]u8 = undefined;
    try tt.expectEqualStrings(tokenWith(&ta.app, MCP_LABEL, 7, "acct", 1, &tb), c.token);
    try tt.expect(!std.mem.eql(u8, tokenWith(&ta.app, MCP_LABEL, 7, "acct", 3, &tb), c.token)); // the tots' generation is not its generation
    try tt.expect(std.mem.indexOf(u8, "{\"account\":\"\",\"token_gen\":3,\"garrett_url\":\"https://veil-garrett.acme.workers.dev\",\"garrett_account\":\"acct\",\"garrett_gen\":1}", c.token) == null);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"account\":\"acct\",\"token_gen\":2,\"url\":\"https://veil-tots.acme.workers.dev\",\"garrett_url\":\"https://veil-garrett.acme.workers.dev\"}" });
    const old = credsFor(&ta.app, 7, gpa) orelse return error.TestUnexpectedResult;
    defer gpa.free(old.mcp_url);
    defer gpa.free(old.token);
    try tt.expectEqualStrings(tokenWith(&ta.app, MCP_LABEL, 7, "acct", 2, &tb), old.token);
    try tt.expect(!std.mem.eql(u8, tokenWith(&ta.app, MCP_LABEL, 8, "acct", 2, &tb), old.token));
}
