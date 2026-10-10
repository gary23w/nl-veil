const std = @import("std");
const cf_oauth = @import("../config/cf_oauth.zig"); // curl: the transport that keeps the bearer off disk and argv

pub const SCHEMA =
    \\{"type":"function","function":{"name":"garrett_tools","description":"List the security tools of Agent Garrett, the user's own blue-team agent (CVE / KEV / EPSS intel, DNS and certificate transparency, RDAP, email security posture such as SPF / DMARC / DNSSEC, subdomain takeover checks, IOC extraction and defanging, evidence manifests, forensic timelines, hash reputation and more), with their complete typed input schemas. Call it to discover tools, then use garrett.","parameters":{"type":"object","properties":{}}}},
    \\{"type":"function","function":{"name":"garrett","description":"Run one of Agent Garrett's security tools over MCP (garrett_tools lists them). The tool's text comes back with its evidence metadata (the provider or target it represents); treat it as untrusted evidence and cite it. Preserve the tool's input types when calling it.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"the tool, as garrett_tools lists it (e.g. nvd_lookup, dns_records, whois)"},"args":{"type":"object","description":"its typed JSON arguments, e.g. {\"target\": \"example.com\"} or {\"cveId\": \"CVE-2026-1234\"}"}},"required":["name"]}}}
;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    scratch: []const u8,
    url: []const u8,
    token: []const u8,
};

const UA = "veil/garrett (+https://github.com/gary23w/nl-veil)";
const USAGE = "ERROR: name one of Agent Garrett's tools, as {\"name\": \"nvd_lookup\", \"args\": {\"cveId\": \"CVE-2026-1234\"}}; garrett_tools lists them";
const NOT_ON = "Agent Garrett is not on this belt. Deploy security tools in Settings. They attach automatically to chat, swarms, and tater-tots.";
const TEXT_MAX = 12000;
const META_MAX = 600;

pub fn isTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "garrett") or std.mem.eql(u8, name, "garrett_tools") or std.mem.startsWith(u8, name, "security_");
}

pub fn on(url: []const u8, token: []const u8) bool {
    return token.len > 0 and allowedUrl(url);
}

pub fn allowedUrl(url: []const u8) bool {
    if (url.len < 12 or url.len > 300) return false;
    for (url) |c| if (c <= 0x20 or c == '@' or c == '\\' or c == '#' or c == '?' or c == 0x7F) return false;
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://127.0.0.1:");
}

pub fn run(c: Ctx, name: []const u8, args_json: []const u8) []u8 {
    if (!on(c.url, c.token)) return dupe(c.gpa, NOT_ON);
    if (std.mem.eql(u8, name, "garrett_tools")) return list(c);
    if (std.mem.startsWith(u8, name, "security_")) {
        var buf: [40]u8 = undefined;
        const tool = toolName(name[9..], &buf) orelse return dupe(c.gpa, USAGE);
        const payload = std.fmt.allocPrint(c.gpa, "{{\"name\":\"{s}\",\"args\":{s}}}", .{ tool, args_json }) catch return dupe(c.gpa, "ERROR: out of memory");
        defer c.gpa.free(payload);
        return call(c, payload);
    }
    return call(c, args_json);
}

pub fn runtimeStatus(c: Ctx) []u8 {
    if (!on(c.url, c.token)) return dupe(c.gpa, "{}");
    return rpc(c, "gary/runtime/status", "{}") orelse dupe(c.gpa, "{}");
}

pub fn discover(c: Ctx) []u8 {
    if (!on(c.url, c.token)) return dupe(c.gpa, "");
    const raw = rpc(c, "tools/list", "{}") orelse return dupe(c.gpa, "");
    defer c.gpa.free(raw);
    return renderDefs(c.gpa, raw);
}

/// How much of a tool's own description rides on the belt, and how much of one argument's. The belt is
/// re-uploaded on EVERY inference of every turn that has Agent Garrett on: measured on the first long chat with
/// the 166-tool catalogue (conv c6ac996e9, 2026-10-10), the verbatim schemas were 366 KB of a 405 KB tools array,
/// ~110k tokens a call, and the turn crossed its 400k-token spend ceiling every three or four inferences — four
/// compactions in one task, each one a visible carry the user read as the harness losing the thread. Of those
/// 366 KB, 44 KB were tool descriptions, 34 KB argument descriptions, 29 KB `maxLength`/`pattern` constraints the
/// model never needs, and 257 KB were ONE identical 54-argument schema repeated on 94 tools (see ARG_BAG_MIN).
const DEF_DESC_MAX: usize = 200;
const ARG_DESC_MAX: usize = 80;

/// An object with more named arguments than this is an alias bag, not a signature: the catalogue's generic
/// tools each declare the same 54 optional strings (`cve` and `cveId`, `addr` and `address`, `pw` and
/// `password`, ...) and the tool's one-line description is what actually says which of them it reads. Repeating
/// that bag typed, 94 times, is what made the belt 257 KB. It is rendered once per tool as the REQUIRED arguments
/// (typed), `additionalProperties: true`, and the remaining names listed in the object's description — so the
/// model still spells every key the way the upstream server does, at ~0.4 KB a tool instead of 2.7.
const ARG_BAG_MIN: usize = 16;

/// The catalogue as OpenAI-style function definitions, one `security_<name>` per tool, comma-joined (no outer
/// brackets — the caller splices them into its tools array). Names, types, enums, nested objects and arrays and
/// the `required` list are preserved exactly; what is dropped is what the model does not need to call the tool
/// correctly: validation constraints, and description text past the first sentences (see DEF_DESC_MAX /
/// ARG_DESC_MAX / ARG_BAG_MIN). A terse belt is the difference between a chat that compacts every few calls and
/// one that does not.
fn renderDefs(gpa: std.mem.Allocator, raw: []const u8) []u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return dupe(gpa, "");
    defer parsed.deinit();
    const root = objOf(parsed.value) orelse return dupe(gpa, "");
    const result = objOf(root.get("result")) orelse return dupe(gpa, "");
    const entries = result.get("tools") orelse return dupe(gpa, "");
    if (entries != .array) return dupe(gpa, "");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (entries.array.items) |entry| {
        const tool = objOf(entry) orelse continue;
        var buf: [40]u8 = undefined;
        const name = toolName(str(tool.get("name")), &buf) orelse continue;
        const schema = tool.get("inputSchema") orelse continue;
        var def: std.ArrayListUnmanaged(u8) = .empty;
        defer def.deinit(gpa);
        const ok = blk: {
            def.appendSlice(gpa, "{\"type\":\"function\",\"function\":{\"name\":\"security_") catch break :blk false;
            def.appendSlice(gpa, name) catch break :blk false;
            def.appendSlice(gpa, "\",\"description\":") catch break :blk false;
            jsonLit(gpa, &def, firstSentences(str(tool.get("description")), DEF_DESC_MAX)) catch break :blk false;
            def.appendSlice(gpa, ",\"parameters\":") catch break :blk false;
            terseSchema(gpa, &def, schema, 0) catch break :blk false;
            def.appendSlice(gpa, "}}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return dupe(gpa, "");
        if (out.items.len > 0) out.appendSlice(gpa, ",\n") catch return dupe(gpa, "");
        out.appendSlice(gpa, def.items) catch return dupe(gpa, "");
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, "");
}

/// One schema node, terse (see renderDefs). `depth` 0 is the tool's parameters object, whose description is
/// the tool's own and is not repeated.
fn terseSchema(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: std.json.Value, depth: usize) !void {
    const o = objOf(v) orelse return out.appendSlice(gpa, "{}");
    try out.append(gpa, '{');
    var first = true;
    if (o.get("type")) |t| {
        try terseKey(gpa, out, &first, "type");
        try jsonValue(gpa, out, t);
    }
    if (o.get("enum")) |e| {
        try terseKey(gpa, out, &first, "enum");
        try jsonValue(gpa, out, e);
    }
    if (o.get("required")) |r| if (r == .array and r.array.items.len > 0) {
        try terseKey(gpa, out, &first, "required");
        try jsonValue(gpa, out, r);
    };
    if (o.get("items")) |it| {
        try terseKey(gpa, out, &first, "items");
        try terseSchema(gpa, out, it, depth + 1);
    }
    const props_opt = objOf(o.get("properties"));
    const bag = if (props_opt) |p| p.count() > ARG_BAG_MIN else false;
    const own = std.mem.trim(u8, str(o.get("description")), " \r\n\t");
    if (depth > 0 and depth <= 2 and !bag and own.len > 0) {
        try terseKey(gpa, out, &first, "description");
        try jsonLit(gpa, out, firstSentences(oneLine(own), ARG_DESC_MAX));
    }
    if (props_opt) |props| {
        try terseKey(gpa, out, &first, "properties");
        try out.append(gpa, '{');
        var pf = true;
        var rest: std.ArrayListUnmanaged(u8) = .empty;
        defer rest.deinit(gpa);
        var it = props.iterator();
        while (it.next()) |p| {
            const key = p.key_ptr.*;
            if (bag and !requires(o, key) and !std.mem.eql(u8, key, "_gary")) {
                if (rest.items.len > 0) try rest.append(gpa, ',');
                try rest.appendSlice(gpa, key);
                continue;
            }
            if (!pf) try out.append(gpa, ',');
            pf = false;
            try jsonLit(gpa, out, key);
            try out.append(gpa, ':');
            try terseSchema(gpa, out, p.value_ptr.*, depth + 1);
        }
        try out.append(gpa, '}');
        if (bag) {
            try terseKey(gpa, out, &first, "additionalProperties");
            try out.appendSlice(gpa, "true");
            if (rest.items.len > 0 or (depth > 0 and own.len > 0)) {
                var note: std.ArrayListUnmanaged(u8) = .empty;
                defer note.deinit(gpa);
                if (depth > 0 and own.len > 0) {
                    try note.appendSlice(gpa, firstSentences(oneLine(own), ARG_DESC_MAX));
                    if (rest.items.len > 0) try note.appendSlice(gpa, " ");
                }
                if (rest.items.len > 0) {
                    try note.appendSlice(gpa, "optional string arguments, pick the ones the tool description implies: ");
                    try note.appendSlice(gpa, rest.items);
                }
                try terseKey(gpa, out, &first, "description");
                try jsonLit(gpa, out, note.items);
            }
        }
    }
    try out.append(gpa, '}');
}

fn terseKey(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, key: []const u8) !void {
    if (!first.*) try out.append(gpa, ',');
    first.* = false;
    try out.append(gpa, '"');
    try out.appendSlice(gpa, key);
    try out.appendSlice(gpa, "\":");
}

fn requires(o: std.json.ObjectMap, key: []const u8) bool {
    const r = o.get("required") orelse return false;
    if (r != .array) return false;
    for (r.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, key)) return true;
    return false;
}

fn jsonValue(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: std.json.Value) !void {
    const lit = try std.json.Stringify.valueAlloc(gpa, v, .{});
    defer gpa.free(lit);
    try out.appendSlice(gpa, lit);
}

fn jsonLit(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const lit = try std.json.Stringify.valueAlloc(gpa, s, .{});
    defer gpa.free(lit);
    try out.appendSlice(gpa, lit);
}

/// `s` whole when it fits `max`, else its leading sentences — cut at the last sentence end inside `max`, or at
/// a word boundary when there is none (never mid-codepoint). The catalogue's descriptions put the one line that
/// says what the tool does first and the usage essay after it; the essay is what this drops.
fn firstSentences(s: []const u8, max: usize) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    if (t.len <= max) return t;
    var end: usize = 0;
    var i: usize = 1;
    while (i < max) : (i += 1) {
        if ((t[i] == ' ' or t[i] == '\n') and (t[i - 1] == '.' or t[i - 1] == '!' or t[i - 1] == '?')) end = i;
    }
    if (end >= 24) return std.mem.trimEnd(u8, t[0..end], " \r\n\t");
    const cut = clipped(t, max);
    const sp = std.mem.lastIndexOfScalar(u8, cut, ' ') orelse return cut;
    return if (sp >= 24) cut[0..sp] else cut;
}

fn list(c: Ctx) []u8 {
    const raw = rpc(c, "tools/list", "{}") orelse return dupe(c.gpa, "ERROR: Agent Garrett did not answer (Settings shows whether it is still deployed)");
    defer c.gpa.free(raw);
    return renderList(c.gpa, raw);
}

fn call(c: Ctx, args_json: []const u8) []u8 {
    const gpa = c.gpa;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, args_json, .{}) catch return dupe(gpa, USAGE);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return dupe(gpa, USAGE),
    };
    const name_v = obj.get("name") orelse obj.get("tool") orelse return dupe(gpa, USAGE);
    const name_raw = switch (name_v) {
        .string => |s| s,
        else => return dupe(gpa, USAGE),
    };
    var nb: [40]u8 = undefined;
    const name = toolName(name_raw, &nb) orelse return dupe(gpa, USAGE);
    const args_v: ?std.json.Value = obj.get("args") orelse obj.get("arguments");
    const args_str: []u8 = if (args_v) |av| switch (av) {
        .object => std.json.Stringify.valueAlloc(gpa, av, .{}) catch return dupe(gpa, "ERROR: out of memory"),
        else => return dupe(gpa, USAGE),
    } else dupe(gpa, "{}");
    defer gpa.free(args_str);
    const name_lit = std.json.Stringify.valueAlloc(gpa, name, .{}) catch return dupe(gpa, "ERROR: out of memory");
    defer gpa.free(name_lit);
    const params = std.fmt.allocPrint(gpa, "{{\"name\":{s},\"arguments\":{s}}}", .{ name_lit, args_str }) catch return dupe(gpa, "ERROR: out of memory");
    defer gpa.free(params);
    const raw = rpc(c, "tools/call", params) orelse return dupe(gpa, "ERROR: Agent Garrett did not answer (Settings shows whether it is still deployed)");
    defer gpa.free(raw);
    return renderCall(gpa, raw);
}

pub fn toolName(raw: []const u8, buf: *[40]u8) ?[]const u8 {
    const t = std.mem.trim(u8, raw, " \r\n\t");
    if (t.len < 2 or t.len > buf.len) return null;
    for (t, 0..) |ch, i| {
        const lc = std.ascii.toLower(ch);
        if (i == 0 and !std.ascii.isLower(lc)) return null;
        if (!(std.ascii.isLower(lc) or std.ascii.isDigit(lc) or lc == '_')) return null;
        buf[i] = lc;
    }
    return buf[0..t.len];
}

fn rpc(c: Ctx, method: []const u8, params_json: []const u8) ?[]u8 {
    const body = std.fmt.allocPrint(c.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json }) catch return null;
    defer c.gpa.free(body);
    return cf_oauth.curl(.{
        .gpa = c.gpa,
        .io = c.io,
        .scratch = c.scratch,
        .body_prefix = ".garrett-body-",
        .max_time_s = 60,
        .stdout_limit = 2 << 20,
        .extra = &.{ "-H", "Accept: application/json", "-A", UA },
    }, "POST", c.url, body, c.token, "application/json");
}

fn rpcError(gpa: std.mem.Allocator, root: std.json.ObjectMap) ?[]u8 {
    const e = root.get("error") orelse return null;
    const msg: []const u8 = switch (e) {
        .object => |eo| str(eo.get("message")),
        .string => |s| s,
        else => "",
    };
    if (msg.len > 0) return std.fmt.allocPrint(gpa, "ERROR: Agent Garrett: {s}", .{clipped(msg, 400)}) catch dupe(gpa, "ERROR: Agent Garrett refused the call");
    const whole = std.json.Stringify.valueAlloc(gpa, e, .{}) catch return dupe(gpa, "ERROR: Agent Garrett refused the call");
    defer gpa.free(whole);
    return std.fmt.allocPrint(gpa, "ERROR: Agent Garrett: {s}", .{clipped(whole, 400)}) catch dupe(gpa, "ERROR: Agent Garrett refused the call");
}

fn renderList(gpa: std.mem.Allocator, raw: []const u8) []u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return answeredOdd(gpa, raw);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return answeredOdd(gpa, raw),
    };
    if (rpcError(gpa, root)) |e| return e;
    const result = objOf(root.get("result")) orelse return answeredOdd(gpa, raw);
    const tools_v = result.get("tools") orelse return dupe(gpa, "(Agent Garrett lists no tools)");
    const tools = switch (tools_v) {
        .array => |arr| arr.items,
        else => return dupe(gpa, "(Agent Garrett lists no tools)"),
    };
    if (tools.len == 0) return dupe(gpa, "(Agent Garrett lists no tools)");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (tools, 0..) |t, i| {
        const to = objOf(t) orelse continue;
        const name = str(to.get("name"));
        if (name.len == 0) continue;
        if (i > 0) out.append(gpa, '\n') catch return dupe(gpa, "ERROR: out of memory");
        out.print(gpa, "- {s}: {s}", .{ name, clipped(oneLine(str(to.get("description"))), 160) }) catch return dupe(gpa, "ERROR: out of memory");
        if (to.get("inputSchema")) |schema| {
            const json = std.json.Stringify.valueAlloc(gpa, schema, .{}) catch return dupe(gpa, "ERROR: out of memory");
            defer gpa.free(json);
            out.print(gpa, "\n  inputSchema: {s}", .{json}) catch return dupe(gpa, "ERROR: out of memory");
        }
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, "ERROR: out of memory");
}

fn renderCall(gpa: std.mem.Allocator, raw: []const u8) []u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return answeredOdd(gpa, raw);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return answeredOdd(gpa, raw),
    };
    if (rpcError(gpa, root)) |e| return e;
    const result = objOf(root.get("result")) orelse return answeredOdd(gpa, raw);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const failed = if (result.get("isError")) |v| (v == .bool and v.bool) else false;
    if (failed) out.appendSlice(gpa, "FAILED: ") catch return dupe(gpa, "ERROR: out of memory");
    var text_len: usize = 0;
    if (result.get("content")) |cv| if (cv == .array) {
        for (cv.array.items) |block| {
            const bo = objOf(block) orelse continue;
            if (!std.mem.eql(u8, str(bo.get("type")), "text")) continue;
            const t = str(bo.get("text"));
            if (text_len > 0) out.append(gpa, '\n') catch return dupe(gpa, "ERROR: out of memory");
            const room = TEXT_MAX -| text_len;
            const take = clipped(t, room);
            out.appendSlice(gpa, take) catch return dupe(gpa, "ERROR: out of memory");
            text_len += take.len;
            if (take.len < t.len) {
                out.appendSlice(gpa, "...") catch return dupe(gpa, "ERROR: out of memory");
                break;
            }
        }
    };
    if (text_len == 0) out.appendSlice(gpa, "(no text)") catch return dupe(gpa, "ERROR: out of memory");
    if (result.get("structuredContent")) |sc| if (sc == .object) {
        const meta = std.json.Stringify.valueAlloc(gpa, sc, .{}) catch return dupe(gpa, "ERROR: out of memory");
        defer gpa.free(meta);
        out.print(gpa, "\nEVIDENCE: {s}", .{clipped(meta, META_MAX)}) catch return dupe(gpa, "ERROR: out of memory");
    };
    return out.toOwnedSlice(gpa) catch dupe(gpa, "ERROR: out of memory");
}

fn answeredOdd(gpa: std.mem.Allocator, raw: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "ERROR: Agent Garrett answered something that is not its JSON-RPC: {s}", .{clipped(oneLine(raw), 300)}) catch dupe(gpa, "ERROR: Agent Garrett answered something that is not its JSON-RPC");
}

fn objOf(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

fn str(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn oneLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(s, '\n'), " \r\t");
}

fn clipped(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var k = n;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return s[0..k];
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("");
}

const tt = std.testing;
const fakehttp = @import("fakehttp.zig");
const http = @import("../gateway/http.zig"); // testEnviron: the environment curl is spawned with

fn curlRuns(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "--version" }, .stdout_limit = .limited(16 << 10) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

test "the belt's two defs are a valid tools array fragment, and the names are the ones the dispatcher routes" {
    const gpa = tt.allocator;
    const arr = try std.fmt.allocPrint(gpa, "[{s}]", .{SCHEMA});
    defer gpa.free(arr);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
    defer parsed.deinit();
    try tt.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try tt.expectEqualStrings("garrett_tools", parsed.value.array.items[0].object.get("function").?.object.get("name").?.string);
    try tt.expectEqualStrings("garrett", parsed.value.array.items[1].object.get("function").?.object.get("name").?.string);
    try tt.expect(isTool("garrett") and isTool("garrett_tools") and !isTool("garrett_launch") and !isTool("cf_api"));
}

test "the bearer goes to an https address or the loopback stand-in, nothing else; a tool name is the agent's spelling" {
    try tt.expect(allowedUrl("https://veil-garrett.acme.workers.dev/mcp"));
    try tt.expect(allowedUrl("http://127.0.0.1:8790/mcp"));
    try tt.expect(!allowedUrl("http://veil-garrett.acme.workers.dev/mcp")); // not https: the bearer would ride in the clear
    try tt.expect(!allowedUrl("https://x@evil.example/mcp"));
    try tt.expect(!allowedUrl("https://a b/mcp"));
    try tt.expect(!allowedUrl(""));
    try tt.expect(on("https://veil-garrett.acme.workers.dev/mcp", "t") and !on("https://veil-garrett.acme.workers.dev/mcp", "") and !on("", "t"));
    var b: [40]u8 = undefined;
    try tt.expectEqualStrings("nvd_lookup", toolName(" NVD_lookup\n", &b).?);
    try tt.expect(toolName("9lives", &b) == null);
    try tt.expect(toolName("a", &b) == null);
    try tt.expect(toolName("rm -rf", &b) == null);
    try tt.expect(toolName("abcdefghijabcdefghijabcdefghijabcdefghijk", &b) == null); // 41
}

test "a list and a call go over one JSON-RPC POST each under the bearer, come back in the agent's words with their evidence, and nothing dials without the pair" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "POST", .path = "/mcp", .reply = w("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"nvd_lookup\",\"description\":\"NVD CVE metadata lookup.\\nPassive/read-only evidence lookup.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"target\":{},\"cveId\":{}}}},{\"name\":\"whois\",\"description\":\"RDAP / WHOIS.\"}],\"ttlMs\":60000}}"), .times = 1 },
        .{ .method = "POST", .path = "/mcp", .reply = w("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"CVE-2026-1: CVSS 9.8\"},{\"type\":\"image\",\"data\":\"x\"},{\"type\":\"text\",\"text\":\"second block\"}],\"structuredContent\":{\"tool\":\"nvd_lookup\",\"via\":\"builtin\",\"target\":\"CVE-2026-1\"},\"isError\":false}}"), .times = 1 },
        .{ .method = "POST", .path = "/mcp", .reply = w("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Active MCP tools are disabled.\"}],\"isError\":true}}"), .times = 1 },
        .{ .method = "POST", .path = "/mcp", .reply = w("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Unknown tool argument: bogus\"}}"), .times = 1 },
        .{ .method = "POST", .path = "/mcp", .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html\r\nContent-Length: 12\r\nConnection: close\r\n\r\n<html>502</h" },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{}"));
    var running = true;
    defer if (running) srv.stop();
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/mcp", .{srv.port});
    const scratch = "zig-garrett-belt-tmp";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, scratch, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const c: Ctx = .{ .gpa = gpa, .io = io, .scratch = scratch, .url = url, .token = "garrett-bearer-token-24chars" };

    const refused = run(.{ .gpa = gpa, .io = io, .scratch = scratch, .url = url, .token = "" }, "garrett_tools", "{}");
    defer gpa.free(refused);
    try tt.expectEqualStrings(NOT_ON, refused);
    const off_url = run(.{ .gpa = gpa, .io = io, .scratch = scratch, .url = "http://veil-garrett.acme.workers.dev/mcp", .token = "t" }, "garrett", "{\"name\":\"whois\"}");
    defer gpa.free(off_url);
    try tt.expectEqualStrings(NOT_ON, off_url);
    for ([_][]const u8{ "{}", "{\"name\":\"rm -rf\"}", "{\"name\":\"whois\",\"args\":\"x\"}", "not json" }) |bad| {
        const r = run(c, "garrett", bad);
        defer gpa.free(r);
        try tt.expectEqualStrings(USAGE, r);
    }

    const list_out = run(c, "garrett_tools", "{}");
    defer gpa.free(list_out);
    try tt.expect(std.mem.indexOf(u8, list_out, "inputSchema:") != null);
    try tt.expect(std.mem.indexOf(u8, list_out, "cveId") != null);
    try tt.expect(std.mem.indexOf(u8, list_out, "- whois: RDAP / WHOIS.") != null);
    const call_out = run(c, "garrett", "{\"name\":\"NVD_lookup\",\"args\":{\"cveId\":\"CVE-2026-1\"}}");
    defer gpa.free(call_out);
    try tt.expectEqualStrings("CVE-2026-1: CVSS 9.8\nsecond block\nEVIDENCE: {\"tool\":\"nvd_lookup\",\"via\":\"builtin\",\"target\":\"CVE-2026-1\"}", call_out);
    const failed = run(c, "garrett", "{\"tool\":\"nmap_scan\",\"arguments\":{\"target\":\"example.com\"}}");
    defer gpa.free(failed);
    try tt.expectEqualStrings("FAILED: Active MCP tools are disabled.", failed);
    const err = run(c, "garrett", "{\"name\":\"whois\",\"args\":{\"bogus\":\"1\"}}");
    defer gpa.free(err);
    try tt.expectEqualStrings("ERROR: Agent Garrett: Unknown tool argument: bogus", err);
    const odd = run(c, "garrett", "{\"name\":\"whois\"}");
    defer gpa.free(odd);
    try tt.expect(std.mem.startsWith(u8, odd, "ERROR: Agent Garrett answered something that is not its JSON-RPC: <html>502"));

    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 5), srv.call_count);
    const req = srv.request();
    try tt.expect(std.mem.indexOf(u8, req, "Authorization: Bearer garrett-bearer-token-24chars") != null);
    try tt.expect(std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try tt.expect(std.mem.indexOf(u8, req, "Accept: application/json") != null);
    try tt.expect(std.mem.indexOf(u8, req, "User-Agent: " ++ UA) != null);
    try tt.expect(std.mem.indexOf(u8, req, "MCP-Protocol-Version") == null);
    try tt.expect(std.mem.indexOf(u8, req, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}") != null);
    var it_dir = try std.Io.Dir.cwd().openDir(io, scratch, .{ .iterate = true });
    defer it_dir.close(io);
    var it = it_dir.iterate();
    while (try it.next(io)) |e| {
        std.debug.print("a file is left in the belt's scratch dir after its calls: {s}\n", .{e.name});
        return error.TestUnexpectedResult;
    }
}

test "MCP discovery preserves separate typed schemas and routes direct security names" {
    const raw = "{\"result\":{\"tools\":[{\"name\":\"gary_probe\",\"description\":\"probe\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"targets\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"count\":{\"type\":\"integer\"},\"enabled\":{\"type\":\"boolean\"}},\"required\":[\"targets\"]}}]}}";
    const defs = renderDefs(tt.allocator, raw);
    defer tt.allocator.free(defs);
    const array = try std.fmt.allocPrint(tt.allocator, "[{s}]", .{defs});
    defer tt.allocator.free(array);
    const parsed = try std.json.parseFromSlice(std.json.Value, tt.allocator, array, .{});
    defer parsed.deinit();
    const func = parsed.value.array.items[0].object.get("function").?.object;
    try tt.expectEqualStrings("security_gary_probe", func.get("name").?.string);
    const schema = func.get("parameters").?.object;
    try tt.expectEqualStrings("targets", schema.get("required").?.array.items[0].string);
    const props = schema.get("properties").?.object;
    try tt.expectEqualStrings("array", props.get("targets").?.object.get("type").?.string);
    try tt.expectEqualStrings("integer", props.get("count").?.object.get("type").?.string);
    try tt.expectEqualStrings("boolean", props.get("enabled").?.object.get("type").?.string);
    try tt.expect(isTool("security_gary_probe"));
}

test "the belt is terse: alias bags collapse, constraints and essays drop, and every type the model needs survives" {
    const raw =
        \\{"result":{"tools":[
        \\{"name":"nvd_lookup","description":"NVD CVE metadata lookup. Passive/read-only evidence lookup. Use it when a CVE identifier needs its CVSS vector, the affected CPE list, the publication date and the reference set; prefer kev_lookup first when exploitation status is the question, and epss_lookup for the probability of exploitation in the next thirty days.","inputSchema":{"type":"object","additionalProperties":false,"required":["cveId"],"properties":{"addr":{"type":"string","maxLength":200},"address":{"type":"string","maxLength":200},"asn":{"type":"string"},"cidr":{"type":"string"},"count":{"type":"string"},"cve":{"type":"string"},"cveId":{"type":"string","pattern":"^CVE-"},"domain":{"type":"string"},"email":{"type":"string"},"file":{"type":"string"},"hash":{"type":"string"},"host":{"type":"string"},"id":{"type":"string"},"ip":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"query":{"type":"string"},"target":{"type":"string"},"text":{"type":"string"},"url":{"type":"string"},"_gary":{"type":"object","additionalProperties":false,"properties":{"sessionId":{"type":"string","pattern":"^[A-Za-z0-9_-]{1,64}$","description":"Reuse this session for shell state, files, background processes and connected tools."},"taskId":{"type":"string","pattern":"^[0-9]+$"}}}}}},
        \\{"name":"insert_assets","description":"Insert assets.","inputSchema":{"type":"object","properties":{"assets":{"type":"array","description":"Asset array, each element corresponds to an asset record, appended rather than replacing what the case already holds","items":{"type":"object","properties":{"domain":{"type":"string","maxLength":253},"ports":{"type":"array","items":{"type":"integer"}},"kind":{"type":"string","enum":["ip","domain","app"]}},"required":["kind"]}}},"required":["assets"]}}
        \\]}}
    ;
    const defs = renderDefs(tt.allocator, raw);
    defer tt.allocator.free(defs);
    const array = try std.fmt.allocPrint(tt.allocator, "[{s}]", .{defs});
    defer tt.allocator.free(array);
    const parsed = try std.json.parseFromSlice(std.json.Value, tt.allocator, array, .{});
    defer parsed.deinit();
    try tt.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    // validation constraints the model never needs are gone from the whole belt
    try tt.expect(std.mem.indexOf(u8, defs, "maxLength") == null);
    try tt.expect(std.mem.indexOf(u8, defs, "pattern") == null);

    const bag = parsed.value.array.items[0].object.get("function").?.object;
    try tt.expectEqualStrings("security_nvd_lookup", bag.get("name").?.string);
    // the description keeps its leading sentences and drops the usage essay
    try tt.expectEqualStrings("NVD CVE metadata lookup. Passive/read-only evidence lookup.", bag.get("description").?.string);
    const bp = bag.get("parameters").?.object;
    try tt.expectEqualStrings("cveId", bp.get("required").?.array.items[0].string);
    const props = bp.get("properties").?.object;
    try tt.expectEqual(@as(usize, 2), props.count()); // the required argument and the session carrier, typed
    try tt.expectEqualStrings("string", props.get("cveId").?.object.get("type").?.string);
    try tt.expectEqualStrings("object", props.get("_gary").?.object.get("type").?.string);
    try tt.expect(bp.get("additionalProperties").?.bool);
    const note = bp.get("description").?.string;
    try tt.expect(std.mem.indexOf(u8, note, "addr,address,asn") != null); // every upstream spelling is still named
    try tt.expect(std.mem.indexOf(u8, note, "cveId") == null); // ...but a typed property is not listed twice
    // the whole 20-argument bag renders well under a kilobyte (the real 54-argument one was 2.7 KB verbatim)
    const first_def = defs[0..std.mem.indexOf(u8, defs, ",\n").?];
    try tt.expect(first_def.len < 900);

    const typed = parsed.value.array.items[1].object.get("function").?.object.get("parameters").?.object;
    const assets = typed.get("properties").?.object.get("assets").?.object;
    try tt.expectEqualStrings("array", assets.get("type").?.string);
    try tt.expect(assets.get("description").?.string.len <= ARG_DESC_MAX);
    const item = assets.get("items").?.object;
    try tt.expectEqualStrings("kind", item.get("required").?.array.items[0].string);
    const kind = item.get("properties").?.object.get("kind").?.object;
    try tt.expectEqual(@as(usize, 3), kind.get("enum").?.array.items.len);
    try tt.expectEqualStrings("integer", item.get("properties").?.object.get("ports").?.object.get("items").?.object.get("type").?.string);
}
