//! netcli.zig — a deliberately tiny HTTP/1.1 client for the LOCAL veil server (127.0.0.1). Only two
//! shapes are needed: an unauthenticated GET /api/v1/fleet for the dashboard counters, and an
//! authenticated POST to deploy a swarm. Everything the console/chat/stop needs comes from the filesystem
//! (scan.zig) — this is only for the two actions that genuinely require the running server. Runs on the
//! poller thread. No keep-alive, no chunked bodies (the server answers these with Content-Length).

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

pub const Resp = struct {
    status: u16 = 0,
    body: []u8 = &.{}, // gpa-owned; caller frees when len>0
};

fn sendRecv(io: Io, gpa: std.mem.Allocator, port: u16, req: []const u8) ?Resp {
    const addr = Io.net.IpAddress{ .ip4 = Io.net.Ip4Address.loopback(port) };
    // No timeout: localhost connects/refuses immediately, and this Zig's Windows connect panics if a
    // timeout option is set (netConnectIpWindows TODO). The read side is bounded by the 1MiB guard.
    var stream = Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |e| {
        log.err("http: connect :{d} failed: {t}", .{ port, e });
        return null;
    };
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(req) catch |e| {
        log.err("http: write failed: {t}", .{e});
        return null;
    };
    w.interface.flush() catch |e| {
        log.err("http: flush failed: {t}", .{e});
        return null;
    };

    // Connection: close means the server ends the body with EOF, so read to end-of-stream in one shot.
    var rbuf: [8192]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const raw = r.interface.allocRemaining(gpa, .limited(1 << 20)) catch |e| {
        log.err("http: read failed: {t}", .{e});
        return null;
    };
    defer gpa.free(raw);
    const resp = parse(gpa, raw);
    if (resp) |rr| log.dbg("http: -> {d} ({d}b)", .{ rr.status, rr.body.len }) else log.warn("http: unparseable response ({d}b)", .{raw.len});
    return resp;
}

fn parse(gpa: std.mem.Allocator, raw: []const u8) ?Resp {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const head = raw[0..sep];
    const body = raw[sep + 4 ..];
    // status line: HTTP/1.1 200 OK
    var status: u16 = 0;
    if (std.mem.indexOfScalar(u8, head, ' ')) |sp| {
        const rest = head[sp + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        status = std.fmt.parseInt(u16, rest[0..end], 10) catch 0;
    }
    return .{ .status = status, .body = gpa.dupe(u8, body) catch &.{} };
}

/// GET /api/v1/fleet — unauthenticated on the server; returns the raw JSON body for the caller to scan.
pub fn fleet(io: Io, gpa: std.mem.Allocator, port: u16) ?Resp {
    const req = std.fmt.allocPrint(gpa, "GET /api/v1/fleet HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAccept: application/json\r\n\r\n", .{}) catch return null;
    defer gpa.free(req);
    return sendRecv(io, gpa, port, req);
}

/// POST a swarm deploy. `token` (if non-empty) is sent as a bearer key so the server's requireUser accepts
/// it; with no token the server will 401 and the caller surfaces "connect a token in Settings".
pub fn deploy(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    const auth = if (token.len > 0)
        std.fmt.allocPrint(gpa, "Authorization: Bearer {s}\r\n", .{token}) catch return null
    else
        gpa.dupe(u8, "") catch return null;
    defer gpa.free(auth);
    const req = std.fmt.allocPrint(gpa, "POST /api/v1/swarms HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ auth, body_json.len, body_json }) catch return null;
    defer gpa.free(req);
    return sendRecv(io, gpa, port, req);
}

test "netcli.deploy exercises the REAL desktop HTTP client against a running server (best-effort)" {
    // Requires: a veil server on :8787 + a valid key at ../data/.desktop_key. If either is missing this
    // returns early (harmless). Point: prove the hand-rolled std.Io.net client works where curl does.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const raw = Io.Dir.cwd().readFileAlloc(io, "../data/.desktop_key", std.testing.allocator, .limited(256)) catch {
        std.debug.print("\n[netcli test] no ../data/.desktop_key — start a server first; skipping\n", .{});
        return;
    };
    defer std.testing.allocator.free(raw);
    const key = std.mem.trim(u8, raw, " \r\n\t");
    std.debug.print("\n[netcli test] key {d} chars prefix={s}\n", .{ key.len, key[0..@min(key.len, 8)] });

    // 1) unauth GET /fleet — proves the client can talk at all
    if (fleet(io, std.testing.allocator, 8787)) |fr| {
        defer if (fr.body.len > 0) std.testing.allocator.free(fr.body);
        std.debug.print("[netcli test] fleet status={d} body={s}\n", .{ fr.status, fr.body[0..@min(fr.body.len, 120)] });
    } else std.debug.print("[netcli test] fleet: NO RESPONSE\n", .{});

    // 2) the actual deploy the button fires
    const body = "{\"name\":\"nettest\",\"provider\":\"mock\",\"model\":\"mock\",\"style\":\"build\",\"stack\":\"general\",\"mode\":\"continuous\",\"base_url\":\"\",\"minutes\":1,\"encrypt\":false,\"veil_population\":false,\"api_key\":\"\",\"gateway_model\":\"\",\"goal\":\"nettest\",\"minds\":[{\"name\":\"nova\",\"role\":\"Lead\",\"duty\":\"build\",\"lead\":true}]}";
    if (deploy(io, std.testing.allocator, 8787, key, body)) |dr| {
        defer if (dr.body.len > 0) std.testing.allocator.free(dr.body);
        std.debug.print("[netcli test] DEPLOY status={d} body={s}\n", .{ dr.status, dr.body[0..@min(dr.body.len, 200)] });
    } else std.debug.print("[netcli test] DEPLOY: NO RESPONSE (client failed)\n", .{});
}

/// DELETE /api/v1/swarms/<id> — the server stops the worker and removes its run dir. Needs the bearer key.
pub fn delete(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8) ?Resp {
    const auth = if (token.len > 0)
        std.fmt.allocPrint(gpa, "Authorization: Bearer {s}\r\n", .{token}) catch return null
    else
        gpa.dupe(u8, "") catch return null;
    defer gpa.free(auth);
    const req = std.fmt.allocPrint(gpa, "DELETE /api/v1/swarms/{s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n{s}\r\n", .{ id, auth }) catch return null;
    defer gpa.free(req);
    return sendRecv(io, gpa, port, req);
}
