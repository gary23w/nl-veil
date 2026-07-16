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

/// Snapshot the interactive elements (refs) plus a clipped page-text excerpt — and, deterministically (so a
/// disabled user's success never depends on the model *noticing*), weave in Pixel RAG and CAPTCHA handling:
///   - STRONG challenge (a real CAPTCHA/interstitial in the DOM) → return a handoff payload, NOT an actionable
///     read; the agent must relay it to the human. We never auto-solve or bypass verification.
///   - thin/canvas/SPA page (little DOM text) → also render screenshot tiles and splice a `visual` block with
///     tile paths + recovered leaf text, so the agent can still act when the DOM read is empty.
///   - SUSPECTED challenge (text-only signal) → non-blocking `challenge` marker, normal read otherwise.
/// `key` is the run_dir (tiles land under it, same convention as pixelrag). Everything is one coherent JSON.
pub fn read(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const snap = try s.snapshot();

    // Decision signals emitted by SNAPSHOT_JS (kind/url copied out before the parse arena is freed).
    const Ch = struct { detected: bool = false, confidence: []const u8 = "none", kind: []const u8 = "unknown" };
    const Sig = struct { textLen: u32 = 0, visualScore: f64 = 0, url: []const u8 = "", challenge: Ch = .{} };
    var text_len: u32 = 0;
    var vscore: f64 = 0;
    var strong = false;
    var suspected = false;
    var kind_buf: [32]u8 = undefined;
    var kind: []const u8 = "unknown";
    var url_buf: [2048]u8 = undefined;
    var cur_url: []const u8 = "";
    if (std.json.parseFromSlice(Sig, gpa, snap, .{ .ignore_unknown_fields = true })) |sp| {
        defer sp.deinit();
        text_len = sp.value.textLen;
        vscore = sp.value.visualScore;
        strong = sp.value.challenge.detected and std.mem.eql(u8, sp.value.challenge.confidence, "strong");
        suspected = sp.value.challenge.detected and std.mem.eql(u8, sp.value.challenge.confidence, "suspected");
        const kl = @min(sp.value.challenge.kind.len, kind_buf.len);
        @memcpy(kind_buf[0..kl], sp.value.challenge.kind[0..kl]);
        kind = kind_buf[0..kl];
        const ul = @min(sp.value.url.len, url_buf.len);
        @memcpy(url_buf[0..ul], sp.value.url[0..ul]);
        cur_url = url_buf[0..ul];
    } else |_| {}

    // 1. STRONG challenge → hand off to the human (never solve). Replaces the normal read.
    if (strong) {
        gpa.free(snap);
        return challengePayload(gpa, io, env, s, key, cur_url, kind);
    }

    // 2. Visual fallback trigger (default ON — it's assistive tech; NL_BROWSER_PIXEL_FALLBACK=0 disables).
    if (!envFalse(env, "NL_BROWSER_PIXEL_FALLBACK")) {
        const text_min = envU32(env, "NL_READ_TEXT_MIN", 80); // genuinely-blank/unhydrated shells run well under this; a real small page (example.com ~127) does not
        const text_rich = envU32(env, "NL_READ_TEXT_RICH", 600);
        var reason: []const u8 = "";
        if (text_len < text_min) {
            reason = "sparse_text"; // blank / unhydrated SPA / challenge shell — little to no readable text
        } else if (vscore >= 0.60 and text_len < text_rich) {
            reason = "canvas_heavy"; // a canvas/map/whiteboard dominates the viewport with little DOM text
        }
        if (reason.len > 0) {
            if (tileCurrentVisual(gpa, io, s, key, cur_url, reason, 3)) |visual| {
                defer gpa.free(visual);
                return spliceField(gpa, snap, "visual", visual); // frees snap on success
            } else |_| {}
        }
    }

    // 3. SUSPECTED challenge → non-blocking marker; the normal read still returns.
    if (suspected) {
        const marker = std.fmt.allocPrint(gpa, "{{\"detected\":true,\"confidence\":\"suspected\",\"kind\":\"{s}\",\"note\":\"possible human-verification prompt on this page — mention it to the user; do not attempt to bypass it\"}}", .{kind}) catch return snap;
        defer gpa.free(marker);
        return spliceField(gpa, snap, "challenge", marker);
    }
    return snap;
}

fn envU32(env: *const std.process.Environ.Map, name: []const u8, dflt: u32) u32 {
    const v = env.get(name) orelse return dflt;
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch dflt;
}

fn envFalse(env: *const std.process.Environ.Map, name: []const u8) bool {
    const v = env.get(name) orelse return false;
    return std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false");
}

/// Splice `"field": value_json` into the snapshot object `snap` (a JSON object string) — strip the trailing
/// '}', append `,"field":<value>}`. Frees `snap`, returns the new gpa-owned string. If `snap` isn't a '}'-
/// terminated object it's returned unchanged (caller still owns/frees `value_json`).
fn spliceField(gpa: std.mem.Allocator, snap: []u8, field: []const u8, value_json: []const u8) []u8 {
    const trimmed = std.mem.trim(u8, snap, " \r\n\t");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return snap;
    const out = std.fmt.allocPrint(gpa, "{s},\"{s}\":{s}}}", .{ trimmed[0 .. trimmed.len - 1], field, value_json }) catch return snap;
    gpa.free(snap);
    return out;
}

/// Tile the CURRENTLY loaded page (no navigate — unlike renderTiles) into up to `max` screenshot tiles written
/// under `{run_dir}/.pixelrag/_read/{hash}/`, returning a `visual` block: tile image PATHS (never inline base64
/// — that would blow the model's context) + per-tile leaf-text excerpts + a recovered_text roll-up. Errors if
/// nothing could be captured (caller then returns the plain snapshot).
fn tileCurrentVisual(gpa: std.mem.Allocator, io: std.Io, s: *Session, run_dir: []const u8, url: []const u8, reason: []const u8, max: u32) Error![]u8 {
    const h = std.hash.Wyhash.hash(0, url);
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/_read/{x}", .{ run_dir, h }) catch return error.OutOfMemory;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};

    const tile_h: i64 = 1600;
    var doc_w: f64 = 1280;
    var doc_h: i64 = tile_h;
    const metrics = s.pageMetrics() catch (gpa.dupe(u8, "{}") catch return error.OutOfMemory);
    defer gpa.free(metrics);
    if (std.json.parseFromSlice(struct { w: f64 = 1280, h: f64 = 0 }, gpa, metrics, .{ .ignore_unknown_fields = true })) |mp| {
        defer mp.deinit();
        if (mp.value.w > 0) doc_w = mp.value.w;
        if (mp.value.h > 0) doc_h = @intFromFloat(mp.value.h);
    } else |_| {}

    const n: u32 = @min(max, @as(u32, @intCast(@max(1, @divTrunc(doc_h + tile_h - 1, tile_h)))));
    var tiles_json: std.ArrayListUnmanaged(u8) = .empty;
    defer tiles_json.deinit(gpa);
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(gpa);
    var i: u32 = 0;
    var written: u32 = 0;
    while (i < n) : (i += 1) {
        const y0: i64 = @as(i64, i) * tile_h;
        const h_px = @min(tile_h, doc_h - y0);
        if (h_px <= 0) break;
        const b64 = s.screenshotClipBase64(0, @floatFromInt(y0), doc_w, @floatFromInt(h_px)) catch continue;
        defer gpa.free(b64);
        const png = decodeB64(gpa, b64) catch continue;
        defer gpa.free(png);
        const full = std.fmt.allocPrint(gpa, "{s}/tile_{d}.png", .{ dir, i }) catch continue;
        defer gpa.free(full);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = png }) catch continue;
        const band = s.bandText(y0, y0 + tile_h) catch (gpa.dupe(u8, "") catch continue);
        defer gpa.free(band);
        const excerpt = if (band.len > 400) band[0..400] else band;
        const ej = std.json.Stringify.valueAlloc(gpa, excerpt, .{}) catch continue;
        defer gpa.free(ej);
        const item = std.fmt.allocPrint(gpa, "{s}{{\"index\":{d},\"image\":\".pixelrag/_read/{x}/tile_{d}.png\",\"excerpt\":{s}}}", .{ if (written > 0) "," else "", i, h, i, ej }) catch continue;
        defer gpa.free(item);
        tiles_json.appendSlice(gpa, item) catch {};
        if (recovered.items.len < 3000 and band.len > 0) {
            if (recovered.items.len > 0) recovered.append(gpa, ' ') catch {};
            recovered.appendSlice(gpa, band) catch {};
        }
        written += 1;
    }
    if (written == 0) return error.Protocol;
    const rec_slice = recovered.items[0..@min(recovered.items.len, 3000)];
    const rec = std.json.Stringify.valueAlloc(gpa, rec_slice, .{}) catch (gpa.dupe(u8, "\"\"") catch return error.OutOfMemory);
    defer gpa.free(rec);
    return std.fmt.allocPrint(gpa, "{{\"fallback\":true,\"reason\":\"{s}\",\"tiles\":[{s}],\"recovered_text\":{s},\"note\":\"Plain read returned little text, so the page was rendered to screenshot tiles. Excerpts are leaf-level text; the images are on disk for a vision pass. If you still can't act, describe the screenshot to the user or call pixel_ingest for a fuller searchable index.\"}}", .{ reason, tiles_json.items, rec }) catch error.OutOfMemory;
}

/// One full-page screenshot to disk for a challenge handoff. Returns the relative image path or null.
fn snapOneShot(gpa: std.mem.Allocator, io: std.Io, s: *Session, run_dir: []const u8, url: []const u8) ?[]u8 {
    const h = std.hash.Wyhash.hash(0, url);
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/_read/{x}", .{ run_dir, h }) catch return null;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    const b64 = s.screenshotBase64() catch return null;
    defer gpa.free(b64);
    const png = decodeB64(gpa, b64) catch return null;
    defer gpa.free(png);
    const full = std.fmt.allocPrint(gpa, "{s}/challenge.png", .{dir}) catch return null;
    defer gpa.free(full);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = png }) catch return null;
    return std.fmt.allocPrint(gpa, ".pixelrag/_read/{x}/challenge.png", .{h}) catch null;
}

/// Build the CAPTCHA/human-verification handoff payload: a screenshot for the human, the URL, and mode-correct
/// instructions. This is the accessibility-correct response — pause and ask the human — NOT an auto-solve.
fn challengePayload(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, s: *Session, run_dir: []const u8, url: []const u8, kind: []const u8) []u8 {
    const headful = wantHeadful(gpa, io, env);
    const title = s.evaluate("document.title") catch (gpa.dupe(u8, "") catch return dupe(gpa, "{\"challenge\":{\"detected\":true,\"confidence\":\"strong\"}}"));
    defer gpa.free(title);
    const shot = snapOneShot(gpa, io, s, run_dir, url);
    defer if (shot) |sp| gpa.free(sp);
    const url_j = std.json.Stringify.valueAlloc(gpa, url, .{}) catch (gpa.dupe(u8, "\"\"") catch return dupe(gpa, "{\"ok\":false}"));
    defer gpa.free(url_j);
    const title_j = std.json.Stringify.valueAlloc(gpa, title, .{}) catch (gpa.dupe(u8, "\"\"") catch return dupe(gpa, "{\"ok\":false}"));
    defer gpa.free(title_j);
    // Own-vs-static tracking so the defer never frees a non-heap literal (the else/OOM path leaves it "null").
    var shot_field: []const u8 = "null";
    var shot_owned = false;
    if (shot) |sp| {
        if (std.fmt.allocPrint(gpa, "\"{s}\"", .{sp})) |f| {
            shot_field = f;
            shot_owned = true;
        } else |_| {}
    }
    defer if (shot_owned) gpa.free(shot_field);
    const instr = if (headful)
        "This page is asking to verify you're human. The browser window is open on your screen — please complete the check yourself (checkbox or puzzle), then tell me to continue. I can't and won't solve it for you."
    else
        "This page needs a human-verification step and the browser is running hidden. Turn the browser window ON in Settings so you can solve it in place, or open this URL in your own browser, complete the check, and tell me to retry.";
    return std.fmt.allocPrint(gpa, "{{\"url\":{s},\"title\":{s},\"challenge\":{{\"detected\":true,\"kind\":\"{s}\",\"confidence\":\"strong\",\"action_required\":\"human\",\"headful\":{},\"screenshot\":{s},\"instructions\":\"{s}\",\"note\":\"Automation paused at a human-verification challenge. I will not bypass or auto-solve it — waiting for you.\"}}}}", .{ url_j, title_j, kind, headful, shot_field, instr }) catch dupe(gpa, "{\"challenge\":{\"detected\":true,\"confidence\":\"strong\"}}");
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
