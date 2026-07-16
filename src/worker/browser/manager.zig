//! Process-global browser-session registry. A session is stateful and must survive across many tool calls
//! (navigate → read → click → …), but tools.execute() runs per-call with a fresh ToolCtx — so sessions live
//! HERE, keyed by run_dir. run_dir is per-user on the chat surface (`.../u{uid}/_chat/...`) and per-run for a
//! cast, so a keyed session never crosses tenants or runs. All ops serialize on ONE mutex: a browser drives a
//! single page and a cast's minds call concurrently. Enable/gating lives at the tools.zig call sites
//! (NL_BROWSER_DRIVER); this module is pure session plumbing.
//!
//! Each op returns a gpa-owned JSON result string ready to hand back as the tool result (caller frees). A
//! browser process is heavy (~1-2s to launch), so the session is opened lazily on first use and reused; the
//! registry caps live sessions and closes the least-recently-used one on overflow. closeAll() is the teardown
//! hook a long-lived host (worker/server) calls on shutdown so no headless browser is orphaned.

const std = @import("std");
const session = @import("session.zig");
const Session = session.Session;

const log = std.log.scoped(.browser);

pub const Error = session.Error;

const MAX_SESSIONS = 4;

const Entry = struct {
    key: []u8, // gpa-owned run_dir
    sess: Session,
    last_used: i64,
    headful: bool = false, // whether this session's browser is visible (vs headless)
};

var g_mu: std.Io.Mutex = .init;
var g_slots: [MAX_SESSIONS]?Entry = .{null} ** MAX_SESSIONS;

/// Whether the browser should be VISIBLE (headful) vs headless. This is a CLIENT selection: the desk writes
/// `{TEMP}/nl-veil-browser.json` = {"headful":bool} from its Settings toggle, and the daemon reads it per
/// session-open so a toggle takes effect on the next session without an env change. NL_BROWSER_HEADFUL overrides.
fn wantHeadful(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("NL_BROWSER_HEADFUL")) |v| {
        if (v.len > 0) return !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
    }
    const base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse return false;
    const path = std.fmt.allocPrint(gpa, "{s}/nl-veil-browser.json", .{base}) catch return false;
    defer gpa.free(path);
    const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024)) catch return false;
    defer gpa.free(txt);
    const P = struct { headful: bool = false };
    const p = std.json.parseFromSlice(P, gpa, txt, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    return p.value.headful;
}

/// Open a fresh session for `key` in the requested headful/headless mode. The profile (+ its live
/// DevToolsActivePort file) MUST live on local disk, never OneDrive (sync locks/delays it → PortTimeout),
/// keyed by a hash of run_dir for per-run isolation.
fn openSession(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, headful: bool) Error!Session {
    const tmp_base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR");
    const profile = if (tmp_base) |tb|
        std.fmt.allocPrint(gpa, "{s}/nl-veil-cdp/{x}", .{ tb, std.hash.Wyhash.hash(0, key) }) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(gpa, "{s}/.browser-profile", .{key}) catch return error.OutOfMemory;
    defer gpa.free(profile);
    return Session.open(gpa, io, env, .{ .user_data_dir = profile, .headless = !headful });
}

/// Find the live session for `key`, or open one. Caller holds g_mu. If a live session's visibility mode no
/// longer matches the current client selection, it is closed and reopened so the toggle takes effect. Returns
/// a pointer into the fixed slot array (stable while the slot is occupied).
fn ensure(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error!*Session {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const headful = wantHeadful(gpa, io, env);
    var free_i: ?usize = null;
    var lru_i: usize = 0;
    var lru_ts: i64 = std.math.maxInt(i64);
    for (&g_slots, 0..) |*slot, i| {
        if (slot.*) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                if (e.headful != headful) { // client toggled visibility → reopen in the new mode
                    log.info("browser: reopening session for {s} (headful={})", .{ key, headful });
                    e.sess.close();
                    e.sess = try openSession(gpa, io, env, key, headful);
                    e.headful = headful;
                }
                e.last_used = now;
                return &e.sess;
            }
            if (e.last_used < lru_ts) {
                lru_ts = e.last_used;
                lru_i = i;
            }
        } else if (free_i == null) {
            free_i = i;
        }
    }
    // No existing session for this key: pick a free slot, else evict the LRU one.
    const idx = free_i orelse blk: {
        if (g_slots[lru_i]) |*e| {
            log.info("browser: evicting LRU session for {s}", .{e.key});
            e.sess.close();
            gpa.free(e.key);
            g_slots[lru_i] = null;
        }
        break :blk lru_i;
    };
    const key_dup = gpa.dupe(u8, key) catch return error.OutOfMemory;
    errdefer gpa.free(key_dup);
    const sess = try openSession(gpa, io, env, key, headful);
    g_slots[idx] = .{ .key = key_dup, .sess = sess, .last_used = now, .headful = headful };
    log.info("browser: opened session for {s} (headful={})", .{ key, headful });
    return &g_slots[idx].?.sess;
}

/// Navigate the session for `key` to `url`; returns {"ok":true,"url":..,"title":..}.
pub fn navigate(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const final = try s.navigate(url);
    defer gpa.free(final);
    const title = s.evaluate("document.title") catch (gpa.dupe(u8, "") catch return error.OutOfMemory);
    defer gpa.free(title);
    log.info("browser: navigated {s} -> {s}", .{ key, final });
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .url = final, .title = title }, .{}) catch error.OutOfMemory;
}

/// Snapshot the interactive elements (refs) plus a clipped page-text excerpt.
pub fn read(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    return s.snapshot();
}

/// Visible page text (document.body.innerText), clipped browser-side to `max` chars.
pub fn pageText(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, max: usize) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const expr = std.fmt.allocPrint(gpa, "(document.body?document.body.innerText:'').slice(0,{d})", .{max}) catch return error.OutOfMemory;
    defer gpa.free(expr);
    return s.evaluate(expr);
}

pub fn click(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, ref: u32) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    log.info("browser: click ref {d} on {s}", .{ ref, key });
    return s.clickRef(ref);
}

pub fn typeText(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, ref: u32, text: []const u8, submit: bool) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    log.info("browser: type into ref {d} on {s} (submit={})", .{ ref, key, submit });
    return s.typeRef(ref, text, submit);
}

pub fn eval(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, js: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    return s.evaluate(js);
}

pub const Tile = struct {
    index: u32,
    y: i64,
    png: []u8, // decoded PNG bytes, gpa-owned
    text: []u8, // gpa-owned band text
};

/// Render `url` and tile the full page into fixed-height screenshot tiles, each paired with the visible text
/// in its band (Pixel RAG's render+ingest stage). Locks the session for the whole render so it is atomic vs
/// concurrent browser tool calls. Caller frees each tile's png+text and the returned slice (freeTiles).
pub fn renderTiles(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8, tile_h: i64, max_tiles: u32) Error![]Tile {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);

    const final = try s.navigate(url);
    gpa.free(final);

    // Full document height → number of tiles (bounded).
    var doc_w: f64 = 1280;
    var doc_h: i64 = tile_h;
    const metrics = s.pageMetrics() catch (gpa.dupe(u8, "{}") catch return error.OutOfMemory);
    defer gpa.free(metrics);
    if (std.json.parseFromSlice(struct { w: f64 = 1280, h: f64 = 0 }, gpa, metrics, .{ .ignore_unknown_fields = true })) |mp| {
        defer mp.deinit();
        if (mp.value.w > 0) doc_w = mp.value.w;
        if (mp.value.h > 0) doc_h = @intFromFloat(mp.value.h);
    } else |_| {}

    const n_tiles: u32 = @min(max_tiles, @as(u32, @intCast(@max(1, @divTrunc(doc_h + tile_h - 1, tile_h)))));
    var tiles: std.ArrayListUnmanaged(Tile) = .empty;
    errdefer {
        for (tiles.items) |t| {
            gpa.free(t.png);
            gpa.free(t.text);
        }
        tiles.deinit(gpa);
    }

    var i: u32 = 0;
    while (i < n_tiles) : (i += 1) {
        const y0: i64 = @as(i64, i) * tile_h;
        const h = @min(tile_h, doc_h - y0);
        if (h <= 0) break;
        const b64 = s.screenshotClipBase64(0, @floatFromInt(y0), doc_w, @floatFromInt(h)) catch continue;
        defer gpa.free(b64);
        const png = decodeB64(gpa, b64) catch continue;
        const text = s.bandText(y0, y0 + tile_h) catch (gpa.dupe(u8, "") catch {
            gpa.free(png);
            continue;
        });
        tiles.append(gpa, .{ .index = i, .y = y0, .png = png, .text = text }) catch {
            gpa.free(png);
            gpa.free(text);
            break;
        };
    }
    log.info("browser: rendered {d} tile(s) for {s}", .{ tiles.items.len, url });
    return tiles.toOwnedSlice(gpa) catch error.OutOfMemory;
}

pub fn freeTiles(gpa: std.mem.Allocator, tiles: []Tile) void {
    for (tiles) |t| {
        gpa.free(t.png);
        gpa.free(t.text);
    }
    gpa.free(tiles);
}

fn decodeB64(gpa: std.mem.Allocator, b64: []const u8) ![]u8 {
    const Dec = std.base64.standard.Decoder;
    const n = try Dec.calcSizeForSlice(b64);
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    try Dec.decode(out, b64);
    return out;
}

/// Close the session for `key` (if any). Returns {"ok":true,"closed":<bool>}.
pub fn closeKey(gpa: std.mem.Allocator, io: std.Io, key: []const u8) []u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*slot| {
        if (slot.*) |*e| if (std.mem.eql(u8, e.key, key)) {
            e.sess.close();
            gpa.free(e.key);
            slot.* = null;
            log.info("browser: closed session for {s}", .{key});
            return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"closed\":true}}", .{}) catch @constCast("{\"ok\":true,\"closed\":true}");
        };
    }
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"closed\":false}}", .{}) catch @constCast("{\"ok\":true,\"closed\":false}");
}

/// Teardown hook: close every live session. A long-lived host calls this on shutdown so no headless browser
/// is orphaned. gpa is the same allocator the sessions were opened with.
pub fn closeAll(gpa: std.mem.Allocator, io: std.Io) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*slot| {
        if (slot.*) |*e| {
            e.sess.close();
            gpa.free(e.key);
            slot.* = null;
        }
    }
}

// -------------------------------------------------- unified action dispatch (broker + in-process + daemon)

var g_last_activity: i64 = 0;

fn touch(io: std.Io) void {
    @atomicStore(i64, &g_last_activity, std.Io.Timestamp.now(io, .real).toSeconds(), .monotonic);
}

/// Seconds (real clock) of the last dispatch() call — the daemon uses this + liveCount for its idle-exit.
pub fn lastActivity() i64 {
    return @atomicLoad(i64, &g_last_activity, .monotonic);
}

pub fn liveCount(io: std.Io) usize {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    var n: usize = 0;
    for (g_slots) |s| {
        if (s != null) n += 1;
    }
    return n;
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("{\"ok\":false}");
}

fn errJson(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch dupe(gpa, "{\"ok\":false}");
}

/// The ONE action dispatcher every surface funnels through: the in-process tool path (browserDispatch when
/// NOT roam), the loopback broker (make_tool bodies), and the local-host daemon (the client-delegated path).
/// `action` is the browser verb (navigate/read/pagetext/click/type/eval/close/ping); `params_json` is a JSON
/// object with its args. Always returns a gpa-owned JSON result string (errors become {"ok":false,"error":..}).
pub fn dispatch(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, action: []const u8, params_json: []const u8) []u8 {
    touch(io);
    if (std.mem.eql(u8, action, "ping")) return dupe(gpa, "{\"ok\":true,\"pong\":true}");

    const pv = std.json.parseFromSlice(std.json.Value, gpa, if (params_json.len == 0) "{}" else params_json, .{}) catch
        return errJson(gpa, "bad params json");
    defer pv.deinit();
    const p = pv.value;

    if (std.mem.eql(u8, action, "navigate")) {
        const url = pStr(p, "url") orelse return errJson(gpa, "need url");
        return navigate(gpa, io, env, key, url) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "read")) {
        return read(gpa, io, env, key) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "pagetext")) {
        const max: usize = if (pInt(p, "max")) |m| @intCast(@max(0, m)) else 4000;
        return pageText(gpa, io, env, key, max) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "click")) {
        const ref = pInt(p, "ref") orelse return errJson(gpa, "need ref");
        return click(gpa, io, env, key, @intCast(@max(0, ref))) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "type")) {
        const ref = pInt(p, "ref") orelse return errJson(gpa, "need ref");
        return typeText(gpa, io, env, key, @intCast(@max(0, ref)), pStr(p, "text") orelse "", pBool(p, "submit")) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "eval")) {
        const js = pStr(p, "js") orelse return errJson(gpa, "need js");
        return eval(gpa, io, env, key, js) catch |e| errJson(gpa, @errorName(e));
    } else if (std.mem.eql(u8, action, "close")) {
        return closeKey(gpa, io, key);
    } else if (std.mem.eql(u8, action, "rendertiles")) {
        const url = pStr(p, "url") orelse return errJson(gpa, "need url");
        const th: i64 = pInt(p, "tile_h") orelse 1600;
        const mt: u32 = if (pInt(p, "max_tiles")) |m| @intCast(@max(1, @min(64, m))) else 12;
        return renderTilesJson(gpa, io, env, key, url, th, mt);
    }
    return errJson(gpa, "unknown action");
}

/// Pixel RAG's render stage as a dispatch action: render `url`, tile it, and return each tile as base64 PNG +
/// band text so a CLIENT-side pixel_ingest (running in a short-lived exec-tool subprocess) can get tiles from
/// the persistent daemon browser and do the indexing itself. gpa-owned JSON.
fn renderTilesJson(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8, tile_h: i64, max_tiles: u32) []u8 {
    const tiles = renderTiles(gpa, io, env, key, url, tile_h, max_tiles) catch |e| return errJson(gpa, @errorName(e));
    defer freeTiles(gpa, tiles);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"tiles\":[") catch return errJson(gpa, "oom");
    const Enc = std.base64.standard.Encoder;
    for (tiles, 0..) |t, i| {
        if (i > 0) out.append(gpa, ',') catch break;
        const b64 = gpa.alloc(u8, Enc.calcSize(t.png.len)) catch break;
        defer gpa.free(b64);
        _ = Enc.encode(b64, t.png);
        const text_lit = std.json.Stringify.valueAlloc(gpa, t.text, .{}) catch (gpa.dupe(u8, "\"\"") catch break);
        defer gpa.free(text_lit);
        const seg = std.fmt.allocPrint(gpa, "{{\"index\":{d},\"y\":{d},\"png\":\"{s}\",\"text\":{s}}}", .{ t.index, t.y, b64, text_lit }) catch break;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch break;
    }
    out.appendSlice(gpa, "]}") catch return errJson(gpa, "oom");
    return out.toOwnedSlice(gpa) catch errJson(gpa, "oom");
}

fn pStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

fn pInt(v: std.json.Value, key: []const u8) ?i64 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .integer => |i| i,
            else => null,
        },
        else => null,
    };
}

fn pBool(v: std.json.Value, key: []const u8) bool {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return false) {
            .bool => |b| b,
            else => false,
        },
        else => false,
    };
}
