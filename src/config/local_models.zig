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
