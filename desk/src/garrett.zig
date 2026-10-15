//! Garrett dashboard handoff: accept a key or the copied MCP configuration.
//! The desktop never needs the user's Cloudflare or Stripe credentials.
const std = @import("std");
pub const dashboard = "https://agent.garrettstimpson.ca/dashboard";
pub const logs = "https://agent.garrettstimpson.ca/logs";
pub fn validKey(key: []const u8) bool {
    if (key.len != 68 or !std.mem.startsWith(u8, key, "gtt_")) return false;
    for (key[4..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}
pub fn copiedKey(a: std.mem.Allocator, text: []const u8) ?[]u8 {
    if (text.len > 8192) return null;
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (validKey(value)) return a.dupe(u8, value) catch null;
    const p = std.json.parseFromSlice(std.json.Value, a, value, .{}) catch return null;
    defer p.deinit();
    if (p.value != .object) return null;
    const servers = p.value.object.get("mcpServers") orelse return null;
    if (servers != .object) return null;
    const agent = servers.object.get("agent-garrett") orelse return null;
    if (agent != .object) return null;
    const headers = agent.object.get("headers") orelse return null;
    if (headers != .object) return null;
    const auth = headers.object.get("Authorization") orelse return null;
    if (auth != .string or !std.mem.startsWith(u8, auth.string, "Bearer ")) return null;
    const key = auth.string[7..];
    if (!validKey(key)) return null;
    // Only the key is handed to the fixed Garrett service; pasted URLs cannot
    // turn onboarding into an arbitrary destination for a credential.
    return a.dupe(u8, key) catch null;
}
test "dashboard handoff accepts real key shape and copied MCP config; rejects placeholders" {
    const a = std.testing.allocator;
    const key = "gtt_" ++ "a" ** 64;
    const raw = copiedKey(a, " \n" ++ key ++ "\r\n").?;
    defer a.free(raw);
    try std.testing.expectEqualStrings(key, raw);
    const config = "{\"mcpServers\":{\"agent-garrett\":{\"url\":\"https://agent.garrettstimpson.ca/mcp\",\"headers\":{\"Authorization\":\"Bearer " ++ key ++ "\"}}}}";
    const copied = copiedKey(a, config).?;
    defer a.free(copied);
    try std.testing.expectEqualStrings(key, copied);
    for ([_][]const u8{ "YOUR_GARRETT_API_KEY", "gtt_short", "Bearer " ++ key, "{\"mcpServers\":{\"other\":{}}}", key ++ "\r\nX: injected", "gtt_" ++ "A" ** 64 }) |bad| try std.testing.expect(copiedKey(a, bad) == null);
}
