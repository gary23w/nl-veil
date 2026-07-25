//! local_models.zig — what Ollama on THIS machine actually has pulled.
//!
//! The shipped catalog (models.yaml → models.json) lists local models that are *worth* running, not
//! ones that *are* installed. A picker built from the catalog alone therefore offers a user a model
//! their machine has never downloaded, and the failure only surfaces on the first turn, as a pull
//! stall or a 404 from Ollama that reads like a bug in the app.
//!
//! So the client asks the server, and the server asks Ollama: GET /api/tags is Ollama's own list of
//! locally-pulled models. Unreachable is a normal answer (no Ollama, or not running) and reports
//! `reachable:false` with an empty list rather than an error — a hosted-only user is not misconfigured.
//!
//! Loopback only, by construction: httpc.request dials 127.0.0.1:<port>, so this cannot be pointed at
//! a remote host and become an SSRF lever.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const httpc = @import("../worker/httpc.zig");

const App = http.App;
const requireUser = http.requireUser;

/// Ollama's default port. Overridable per request with ?port= so a non-standard install still works,
/// bounded to a real port number; anything else falls back to the default rather than erroring.
const OLLAMA_PORT: u16 = 11434;

/// Just the field we need out of Ollama's /api/tags reply:
///   {"models":[{"name":"gpt-oss:20b","size":…,"details":{…}}, …]}
const Tag = struct { name: []const u8 = "" };
const Tags = struct { models: []const Tag = &.{} };

/// GET /api/v1/models/local → {ok:true, reachable:bool, port:int, installed:["gpt-oss:20b", …]}
pub fn list(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = requireUser(app, req, res) orelse return;

    var port: u16 = OLLAMA_PORT;
    if (req.query()) |q| {
        if (q.get("port")) |p| {
            if (std.fmt.parseInt(u16, std.mem.trim(u8, p, " \r\n\t"), 10)) |v| {
                if (v != 0) port = v;
            } else |_| {}
        }
    } else |_| {}

    const arena = res.arena;
    var names: std.ArrayList([]const u8) = .empty;
    var reachable = false;

    // 3s: a live Ollama answers /api/tags in milliseconds, and a picker must not hang on a dead port.
    const r = httpc.request(app.io, arena, .{
        .method = "GET",
        .port = port,
        .path = "/api/tags",
        .timeout_s = 3,
        .cap = 1 << 20,
    });

    switch (r) {
        .ok => |resp| {
            reachable = true;
            const parsed = std.json.parseFromSlice(Tags, arena, resp.body, .{ .ignore_unknown_fields = true }) catch {
                // Something answered on the port but it is not Ollama. Reachable, nothing installed —
                // more honest than claiming a parse error the user can do nothing about.
                try writeOut(res, true, port, names.items);
                return;
            };
            for (parsed.value.models) |m| {
                if (m.name.len != 0) try names.append(arena, m.name);
            }
        },
        // refused / timed_out / failed are all "no local Ollama here", which is a normal state.
        else => reachable = false,
    }

    try writeOut(res, reachable, port, names.items);
}

fn writeOut(res: *httpz.Response, reachable: bool, port: u16, installed: []const []const u8) !void {
    try res.json(.{
        .ok = true,
        .reachable = reachable,
        .port = port,
        .installed = installed,
    }, .{});
}

// ---------------------------------------------------------------------------
// tests — the two halves of the contract in the header: what a REAL /api/tags reply turns into, and
// what happens when whatever is on the other end is not Ollama, or is not there at all. Both run
// through the HANDLER (harness/TESTING.md: http.testApp + httpz.testing, never an extracted helper)
// against a throwaway loopback server serving canned bytes. `?port=` is what makes that possible
// without pointing the suite at whatever the developer's box happens to have running on 11434.
//
// Deliberately NOT asserted: that a real Ollama answers. That test would pass on one machine and
// skip on every other, and the regression it would catch — Ollama adding fields to /api/tags — is
// what the additive-fields test below pins directly.
// ---------------------------------------------------------------------------

/// TEST ONLY. A loopback server that answers EVERY connection with the same canned bytes, and counts
/// them. `stop` is safe no matter how many requests actually arrived: it raises the shutdown flag and
/// then dials its own port once, so a serve loop parked in `accept` always wakes and exits. Without
/// that, a test whose handler never dialed (the auth-gate one, on purpose) would leave the thread
/// blocked forever and hang the whole runner instead of failing.
const FakeOllama = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    reply: []const u8,
    conns: std.atomic.Value(u32),
    closing: std.atomic.Value(bool),
    thread: std.Thread,

    /// Starts in place: the serve thread holds a pointer to this struct, so it must not be copied.
    fn startAt(self: *FakeOllama, io: std.Io, port: u16, reply: []const u8) !void {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        self.server = try std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp });
        self.io = io;
        self.reply = reply;
        self.port = port;
        self.conns = .init(0);
        self.closing = .init(false);
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch |e| {
            self.server.deinit(io);
            return e;
        };
    }

    fn start(self: *FakeOllama, io: std.Io, reply: []const u8) !void {
        var port: u16 = 47431;
        while (port < 47530) : (port += 1) {
            self.startAt(io, port, reply) catch continue;
            return;
        }
        return error.SkipZigTest; // no free loopback port in the scan range
    }

    fn serve(self: *FakeOllama) void {
        while (true) {
            const conn = self.server.accept(self.io) catch return;
            defer conn.close(self.io);
            if (self.closing.load(.acquire)) return; // that was stop()'s wake-up dial
            _ = self.conns.fetchAdd(1, .monotonic);
            // Drain the request head first. httpc writes the whole request before it reads, and a peer
            // that answers-and-closes without reading can reset the connection out from under it.
            var rbuf: [4 << 10]u8 = undefined;
            var rd = conn.reader(self.io, &rbuf);
            while (true) {
                const line = (rd.interface.takeDelimiter('\n') catch break) orelse break;
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            var wbuf: [8 << 10]u8 = undefined;
            var wr = conn.writer(self.io, &wbuf);
            wr.interface.writeAll(self.reply) catch {};
            wr.interface.flush() catch {};
        }
    }

    fn stop(self: *FakeOllama) void {
        self.closing.store(true, .release);
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(self.port) };
        if (std.Io.net.IpAddress.connect(&addr, self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
    }
};

/// TEST ONLY. One HTTP/1.1 reply with real Content-Length framing, built at comptime from its body.
fn wire(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

/// TEST ONLY. The handler's answer, lifted out of the httpz test arena so an assertion can outlive it.
const Answer = struct {
    status: u16,
    body: []u8,
    fn deinit(self: Answer, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

/// TEST ONLY. One `list` call with `?port=<port_str>` (or none at all when null).
fn ask(gpa: std.mem.Allocator, ta: *http.TestApp, cookie: []const u8, port_str: ?[]const u8) !Answer {
    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("cookie", cookie);
    if (port_str) |p| web.query("port", p); // httpz keeps this BY REFERENCE — `p` must outlive the call
    try list(&ta.app, web.req, web.res);
    return .{ .status = web.res.status, .body = try gpa.dupe(u8, try web.getBody()) };
}

/// TEST ONLY. One `list` call against a fake Ollama serving exactly `reply`. The fake is JOINED before
/// this returns, so an assertion that fails afterwards can never strand its accept thread.
fn askFake(gpa: std.mem.Allocator, io: std.Io, ta: *http.TestApp, cookie: []const u8, reply: []const u8) !Answer {
    var fake: FakeOllama = undefined;
    try fake.start(io, reply);
    defer fake.stop();
    var pbuf: [8]u8 = undefined;
    return ask(gpa, ta, cookie, std.fmt.bufPrint(&pbuf, "{d}", .{fake.port}) catch unreachable);
}

/// TEST ONLY. Decode the reply and assert the whole documented shape at once: `ok`, `reachable` and
/// `installed`, at HTTP 200. Every case in this file answers 200 — that is the point of the endpoint.
fn expectAnswer(gpa: std.mem.Allocator, ans: Answer, reachable: bool, installed: []const []const u8) !void {
    try std.testing.expectEqual(@as(u16, 200), ans.status);
    const p = try std.json.parseFromSlice(std.json.Value, gpa, ans.body, .{});
    defer p.deinit();
    const o = p.value.object;
    try std.testing.expect(o.get("ok").?.bool);
    try std.testing.expectEqual(reachable, o.get("reachable").?.bool);
    const arr = o.get("installed").?.array;
    try std.testing.expectEqual(installed.len, arr.items.len);
    for (installed, arr.items) |want, got| try std.testing.expectEqualStrings(want, got.string);
}

/// TEST ONLY. The port the endpoint says it dialed.
fn portOf(gpa: std.mem.Allocator, ans: Answer) !u16 {
    const p = try std.json.parseFromSlice(std.json.Value, gpa, ans.body, .{});
    defer p.deinit();
    return @intCast(p.value.object.get("port").?.integer);
}

/// TEST ONLY. A real account and a real session, through the same doors the server uses. Auth fails
/// OPEN off its in-memory maps, so this works with no neuron binary present — which is CI's normal
/// state — and this endpoint never touches the store, so there is nothing else to probe for.
fn loginCookie(gpa: std.mem.Allocator, ta: *http.TestApp) ![]u8 {
    ta.auth.register("picker@example.test", "correct horse battery") catch return error.SkipZigTest;
    const token = ta.auth.login("picker@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(token);
    return std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{token});
}

test "the auth gate runs before the local dial: an anonymous caller is refused and Ollama is never contacted" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-gate-tmp");
    defer ta.deinit();

    var fake: FakeOllama = undefined;
    try fake.start(io, wire(
        \\{"models":[{"name":"gpt-oss:20b"}]}
    ));
    var web = httpz.testing.init(.{});
    defer web.deinit();
    var pbuf: [8]u8 = undefined;
    web.query("port", std.fmt.bufPrint(&pbuf, "{d}", .{fake.port}) catch unreachable);
    list(&ta.app, web.req, web.res) catch |e| {
        fake.stop();
        return e;
    };
    fake.stop(); // joined BEFORE the assertions, so a red test cannot hang the runner

    try web.expectStatus(401);
    // The property is not "it answered 401" — an edit that moved requireUser below httpc.request would
    // still answer 401. It is that an unauthenticated caller cannot make this server probe a local port.
    try std.testing.expectEqual(@as(u32, 0), fake.conns.load(.acquire));
}

test "a well-formed /api/tags reply becomes exactly the installed list, in order" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-ok-tmp");
    defer ta.deinit();
    const cookie = try loginCookie(gpa, ta);
    defer gpa.free(cookie);

    // Ollama's real shape, fields and all: the picker takes the `name`s, in the order Ollama listed
    // them, and nothing else off the record.
    const ans = try askFake(gpa, io, ta, cookie, wire(
        \\{"models":[{"name":"gpt-oss:20b","model":"gpt-oss:20b","size":13780173724,"digest":"e1f2","details":{"family":"gptoss","parameter_size":"20.9B","quantization_level":"MXFP4"}},{"name":"llama3.1:8b","size":4920753328},{"name":"nomic-embed-text:latest"}]}
    ));
    defer ans.deinit(gpa);
    try expectAnswer(gpa, ans, true, &.{ "gpt-oss:20b", "llama3.1:8b", "nomic-embed-text:latest" });
}

test "additive server fields are ignored, and a model with no usable name is dropped rather than listed as a phantom" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-additive-tmp");
    defer ta.deinit();
    const cookie = try loginCookie(gpa, ta);
    defer gpa.free(cookie);

    // Ollama is free to add fields, at the top level and per model, and a picker that goes blank the
    // day it does is worse than no picker. Every unknown key here must be skipped — including nested
    // objects and arrays — while `name` still lands. The two nameless entries are the other half: a
    // default-empty name is NOT a model, and offering "" in a picker would 404 on the first turn.
    const ans = try askFake(gpa, io, ta, cookie, wire(
        \\{"models":[{"name":""},{"size":1,"details":{"families":["a","b"]}},{"name":"real:latest","future_field":{"deep":[1,2,{"x":null}]}}],"total":3,"next_page":null,"server":{"version":"9.9.9"}}
    ));
    defer ans.deinit(gpa);
    try expectAnswer(gpa, ans, true, &.{"real:latest"});
}

test "something that is not Ollama on the port is reachable-with-nothing-installed, never an error the user sees" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-garbage-tmp");
    defer ta.deinit();
    const cookie = try loginCookie(gpa, ta);
    defer gpa.free(cookie);

    // Every one of these is SOMETHING answering on the port — a dev server, a proxy, a newer Ollama
    // that broke its own contract, a half-written reply. None of them is a bug the user can act on,
    // so none of them may surface as a failure: 200, ok, reachable, empty list.
    const not_ollama = [_][]const u8{
        wire("<html><body>it me, a dev server</body></html>"), // valid HTTP, not JSON at all
        wire("{\"models\":[{\"name\":\"gpt-oss:2"), // truncated mid-reply
        wire("{\"models\":\"not-an-array\"}"), // right key, wrong type
        wire(""), // Content-Length: 0
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nnot found", // wrong route
        wire("{}"), // valid JSON, no models key at all
        wire("{\"models\":[]}"), // Ollama installed, nothing pulled
    };
    for (not_ollama) |reply| {
        const ans = try askFake(gpa, io, ta, cookie, reply);
        defer ans.deinit(gpa);
        try expectAnswer(gpa, ans, true, &.{});
    }
}

test "an unreachable backend is indistinguishable from nothing installed: 200 with reachable false, never a failure" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-dead-tmp");
    defer ta.deinit();
    const cookie = try loginCookie(gpa, ta);
    defer gpa.free(cookie);

    // Bind a port and release it, so we KNOW nothing is listening there — the state of a machine with
    // no Ollama, which is the normal state for a hosted-only user and must never read as misconfigured.
    var fake: FakeOllama = undefined;
    try fake.start(io, wire("{}"));
    const dead_port = fake.port;
    fake.stop();

    var pbuf: [8]u8 = undefined;
    const ans = try ask(gpa, ta, cookie, std.fmt.bufPrint(&pbuf, "{d}", .{dead_port}) catch unreachable);
    defer ans.deinit(gpa);
    try expectAnswer(gpa, ans, false, &.{});
    try std.testing.expectEqual(dead_port, try portOf(gpa, ans)); // and it reports which port it tried
}

test "the ?port override is bounded: only a real non-zero port wins, and anything else falls back to the default" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-localmodels-port-tmp");
    defer ta.deinit();
    const cookie = try loginCookie(gpa, ta);
    defer gpa.free(cookie);

    // A real port wins, and survives the whitespace a form or a shell adds.
    {
        var fake: FakeOllama = undefined;
        try fake.start(io, wire(
            \\{"models":[{"name":"gpt-oss:20b"}]}
        ));
        defer fake.stop();
        var pbuf: [16]u8 = undefined;
        const padded = std.fmt.bufPrint(&pbuf, "  {d}\r\n", .{fake.port}) catch unreachable;
        const ans = try ask(gpa, ta, cookie, padded);
        defer ans.deinit(gpa);
        try std.testing.expectEqual(fake.port, try portOf(gpa, ans));
        try expectAnswer(gpa, ans, true, &.{"gpt-oss:20b"});
    }

    // Take over the DEFAULT port for the rest of the test, when this box is not already running the
    // real thing there. Two reasons: the fallback is then proven to have DIALED OLLAMA_PORT rather
    // than merely echoed it, and the run stops spraying the log with the stack dump Windows prints
    // for every refused connect — the noise check.sh warns buries real failures.
    var def: FakeOllama = undefined;
    const own_default = if (def.startAt(io, OLLAMA_PORT, wire(
        \\{"models":[{"name":"answered-on-the-default-port:1"}]}
    ))) |_| true else |_| false;
    defer if (own_default) def.stop();

    // Everything a query string can carry that is NOT a port falls back to the module's own default,
    // rather than erroring at a user who typed something odd into a URL. Port 0 is in that set: it is
    // a legal u16 and a meaningless destination.
    for ([_]?[]const u8{ null, "0", "70000", "-1", "notaport", "", "11434junk" }) |bad| {
        const ans = try ask(gpa, ta, cookie, bad);
        defer ans.deinit(gpa);
        try std.testing.expectEqual(@as(u16, OLLAMA_PORT), try portOf(gpa, ans));
        try std.testing.expectEqual(@as(u16, 200), ans.status);
        if (own_default) try expectAnswer(gpa, ans, true, &.{"answered-on-the-default-port:1"});
    }
}
