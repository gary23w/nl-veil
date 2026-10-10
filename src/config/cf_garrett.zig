
const std = @import("std");
const http = @import("../gateway/http.zig");
const App = http.App;

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
