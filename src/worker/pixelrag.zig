//! Pixel RAG (Feature 1, Phase A) — ingest a web page as RENDERED screenshot tiles and retrieve over them,
//! instead of parsing HTML to text. Adapts StarTrail-org/PixelRAG's render→ingest→index→serve shape to
//! nl-veil's stack: the shared browser session (browser/manager.zig) renders and tiles the page; each tile's
//! visible band-text is stored into neuron-db (the index); pixel_search retrieves tiles by a lexical score over
//! that corpus and returns each tile's image path + text excerpt.
//!
//! DELIBERATE Phase-A divergence from PixelRAG (see PIXEL_BROWSER_BLUEPRINT.md): nl-veil has no vision embedding
//! model and no FAISS, and a local Qwen3-VL-Embedding would break "no new manual install". So Phase A is
//! VISION-AS-TEXT with no vision model: the retrievable text is the page's own rendered DOM text (captured per
//! tile band), indexed in neuron-db and scored lexically. The tiles are still rendered SCREENSHOTS, so Phase B
//! (feed the tile image back to a vision model) is a drop-in on the same tiles. The retrieval stage is
//! swappable: NL_PIXELRAG_EMBED_URL is the seam for a future multimodal-embedding index (not wired in Phase A).

const std = @import("std");
const browser_mgr = @import("browser/manager.zig");
const browser_host = @import("browser/host.zig");
const osc = @import("oscillation.zig");
const Mem = osc.Mem;

const log = std.log.scoped(.pixelrag);

/// neuron-db scope holding the tile corpus. Each stored fact is `<band text>\x1e<doc>\x1f<tile>\x1f<rel img>`.
pub const PIXEL_SCOPE = "pixelrag";
const MARK: u8 = 0x1e; // separates a tile's text from its metadata
const FSEP: u8 = 0x1f; // separates metadata fields
const TILE_H: i64 = 1600; // tile height in CSS px
const MAX_TILES: u32 = 12;
const MAX_TEXT: usize = 2800; // clip stored band text

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("");
}

/// Copy `s` with every control byte (< 0x20 — newlines especially) replaced by a space, and runs of spaces
/// collapsed. Keeps the fact single-line so neuron-db's newline-delimited store/export round-trips it intact.
fn sanitizeLine(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var prev_space = false;
    for (s) |c| {
        const ch: u8 = if (c < 0x20) ' ' else c;
        if (ch == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

/// Sanitize an explicit doc_id, or derive a stable one from the URL host + a hash when none is given. Owned.
fn resolveDocId(gpa: std.mem.Allocator, doc_id: []const u8, url: []const u8) []u8 {
    const t = std.mem.trim(u8, doc_id, " \r\n\t");
    if (t.len > 0 and t.len <= 48) {
        var ok = true;
        for (t) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) {
                ok = false;
                break;
            }
        }
        if (ok) return gpa.dupe(u8, t) catch @constCast("doc");
    }
    // derive: host (alnum only) + short hash of the full url
    var host = url;
    if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
    if (std.mem.indexOfAny(u8, host, "/?#")) |i| host = host[0..i];
    var hb: std.ArrayListUnmanaged(u8) = .empty;
    defer hb.deinit(gpa);
    for (host) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) hb.append(gpa, c) catch {};
        if (hb.items.len >= 24) break;
    }
    const h = std.hash.Wyhash.hash(0, url);
    return std.fmt.allocPrint(gpa, "{s}-{x}", .{ if (hb.items.len > 0) hb.items else "page", h & 0xffffff }) catch @constCast("doc");
}

/// Render `url`, tile it, and index each tile's band-text into neuron-db. Returns a JSON summary.
/// Write one tile's PNG under .pixelrag/{doc}/tile_{index}.png, store its band-text in neuron-db, and append a
/// manifest line. Returns the tile's text length; bumps `*indexed` when non-empty text was stored.
fn indexOne(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, mem: Mem, doc_id: []const u8, index: u32, png: []const u8, text_in: []const u8, manifest_add: *std.ArrayListUnmanaged(u8), indexed: *u32) usize {
    const img_rel = std.fmt.allocPrint(gpa, ".pixelrag/{s}/tile_{d}.png", .{ doc_id, index }) catch return 0;
    defer gpa.free(img_rel);
    const img_abs = std.fmt.allocPrint(gpa, "{s}/{s}", .{ run_dir, img_rel }) catch return 0;
    defer gpa.free(img_abs);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = img_abs, .data = png }) catch {};

    const text = std.mem.trim(u8, text_in, " \r\n\t");
    if (text.len == 0) return 0;
    const raw = if (text.len > MAX_TEXT) text[0..MAX_TEXT] else text;
    const clean = sanitizeLine(gpa, raw) catch return text.len; // keep the fact single-line (neuron store is line-delimited)
    defer gpa.free(clean);
    const fact = std.fmt.allocPrint(gpa, "{s}{c}{s}{c}{d}{c}{s}", .{ clean, MARK, doc_id, FSEP, index, FSEP, img_rel }) catch return text.len;
    defer gpa.free(fact);
    _ = mem.observe(PIXEL_SCOPE, fact); // durable neuron-db store (also the Phase-B semantic substrate)
    const entry = std.json.Stringify.valueAlloc(gpa, .{ .doc = doc_id, .tile = index, .img = img_rel, .text = clean }, .{}) catch return text.len;
    defer gpa.free(entry);
    manifest_add.appendSlice(gpa, entry) catch {};
    manifest_add.append(gpa, '\n') catch {};
    indexed.* += 1;
    return text.len;
}

const RTile = struct { index: u32 = 0, y: i64 = 0, png: []const u8 = "", text: []const u8 = "" };
const RTResp = struct { ok: bool = false, tiles: []const RTile = &.{} };

/// Render `url` and index its tiles. Under `use_daemon` (subprocess-per-call clients: `veil exec-tool`), the
/// render is done by the persistent local-host daemon (so pixel_ingest reuses ONE browser and doesn't leak Edge
/// across the desk's per-call subprocesses) and the indexing is done here; a long-lived server/swarm/CLI-direct
/// caller renders in-process. Returns a JSON summary.
pub fn ingest(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, run_dir: []const u8, mem: Mem, url: []const u8, doc_id_in: []const u8, use_daemon: bool) []u8 {
    const doc_id = resolveDocId(gpa, doc_id_in, url);
    defer gpa.free(doc_id);
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/{s}", .{ run_dir, doc_id }) catch return dupe(gpa, "oom");
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};

    var indexed: u32 = 0;
    var total_chars: usize = 0;
    var tile_count: usize = 0;
    var manifest_add: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest_add.deinit(gpa);

    if (use_daemon) {
        // Render on the local-host daemon; it returns base64 tiles we decode + index here.
        const url_lit = std.json.Stringify.valueAlloc(gpa, url, .{}) catch return dupe(gpa, "oom");
        defer gpa.free(url_lit);
        const params = std.fmt.allocPrint(gpa, "{{\"url\":{s},\"tile_h\":{d},\"max_tiles\":{d}}}", .{ url_lit, TILE_H, MAX_TILES }) catch return dupe(gpa, "oom");
        defer gpa.free(params);
        const resp = browser_host.forward(gpa, io, env, run_dir, "rendertiles", params);
        defer gpa.free(resp);
        const parsed = std.json.parseFromSlice(RTResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch
            return std.fmt.allocPrint(gpa, "pixel_ingest render failed: {s}", .{clip(resp, 200)}) catch dupe(gpa, "render failed");
        defer parsed.deinit();
        if (!parsed.value.ok) return std.fmt.allocPrint(gpa, "pixel_ingest render failed: {s}", .{clip(resp, 200)}) catch dupe(gpa, "render failed");
        const Dec = std.base64.standard.Decoder;
        tile_count = parsed.value.tiles.len;
        for (parsed.value.tiles) |t| {
            const n = Dec.calcSizeForSlice(t.png) catch continue;
            const png = gpa.alloc(u8, n) catch continue;
            defer gpa.free(png);
            Dec.decode(png, t.png) catch continue;
            total_chars += indexOne(gpa, io, run_dir, mem, doc_id, t.index, png, t.text, &manifest_add, &indexed);
        }
    } else {
        const tiles = browser_mgr.renderTiles(gpa, io, env, run_dir, url, TILE_H, MAX_TILES) catch |e|
            return std.fmt.allocPrint(gpa, "pixel_ingest failed to render: {s}", .{@errorName(e)}) catch dupe(gpa, "render failed");
        defer browser_mgr.freeTiles(gpa, tiles);
        tile_count = tiles.len;
        for (tiles) |t| total_chars += indexOne(gpa, io, run_dir, mem, doc_id, t.index, t.png, t.text, &manifest_add, &indexed);
    }

    if (manifest_add.items.len > 0) appendManifest(gpa, io, run_dir, manifest_add.items);
    log.info("pixel_ingest {s}: {d} tiles, {d} indexed, {d} chars (daemon={})", .{ doc_id, tile_count, indexed, total_chars, use_daemon });
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"doc_id\":\"{s}\",\"tiles\":{d},\"indexed\":{d},\"chars\":{d},\"note\":\"rendered + indexed; retrieve with pixel_search\"}}", .{ doc_id, tile_count, indexed, total_chars }) catch dupe(gpa, "ingested");
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

fn manifestPath(gpa: std.mem.Allocator, run_dir: []const u8) ?[]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.pixelrag/index.jsonl", .{run_dir}) catch null;
}

fn appendManifest(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, lines: []const u8) void {
    const path = manifestPath(gpa, run_dir) orelse return;
    defer gpa.free(path);
    const prior = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, prior) catch return;
    buf.appendSlice(gpa, lines) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
}

const Entry = struct { doc: []const u8 = "", tile: i64 = 0, img: []const u8 = "", text: []const u8 = "" };

/// Retrieve the top-k tiles whose band-text best matches `query` (lexical: distinct query-stem hits) by reading
/// the per-run manifest index. Returns a JSON array of {doc_id, tile, image, score, excerpt}. Phase-A default
/// retriever; NL_PIXELRAG_EMBED_URL is the seam for a future embedding-based one.
pub fn search(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, query: []const u8, k: u32) []u8 {
    const path = manifestPath(gpa, run_dir) orelse return dupe(gpa, "oom");
    defer gpa.free(path);
    const all = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch
        return dupe(gpa, "{\"ok\":true,\"count\":0,\"results\":[],\"note\":\"nothing ingested yet — call pixel_ingest first\"}");
    defer gpa.free(all);

    // Query stems: lowercased alnum tokens, length >= 3, deduped (bounded).
    var stems: [24][]const u8 = undefined;
    var stem_buf: [24][40]u8 = undefined;
    var n_stems: usize = 0;
    {
        var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:!?()[]{}\"'/\\-_");
        while (it.next()) |tok| {
            if (n_stems >= stems.len) break;
            if (tok.len < 3 or tok.len > 40) continue;
            const low = std.ascii.lowerString(&stem_buf[n_stems], tok);
            var dup = false;
            for (stems[0..n_stems]) |s| if (std.mem.eql(u8, s, low)) {
                dup = true;
                break;
            };
            if (dup) continue;
            stems[n_stems] = low;
            n_stems += 1;
        }
    }

    const Hit = struct { score: u32, doc: []const u8, tile: i64, image: []const u8, excerpt: []const u8 };
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    defer hits.deinit(gpa);
    var lower_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer lower_buf.deinit(gpa);
    var parsed_list: std.ArrayListUnmanaged(std.json.Parsed(Entry)) = .empty;
    defer {
        for (parsed_list.items) |*pp| pp.deinit();
        parsed_list.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, all, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \r\n\t");
        if (line.len < 2) continue;
        const pe = std.json.parseFromSlice(Entry, gpa, line, .{ .ignore_unknown_fields = true }) catch continue;
        const e = pe.value;
        // score: distinct query stems present in the (lowercased) tile text
        lower_buf.clearRetainingCapacity();
        lower_buf.appendSlice(gpa, e.text) catch {
            pe.deinit();
            continue;
        };
        for (lower_buf.items) |*c| c.* = std.ascii.toLower(c.*);
        var score: u32 = 0;
        for (stems[0..n_stems]) |s| {
            if (std.mem.indexOf(u8, lower_buf.items, s) != null) score += 1;
        }
        if (score == 0) {
            pe.deinit();
            continue;
        }
        hits.append(gpa, .{ .score = score, .doc = e.doc, .tile = e.tile, .image = e.img, .excerpt = if (e.text.len > 240) e.text[0..240] else e.text }) catch {
            pe.deinit();
            break;
        };
        parsed_list.append(gpa, pe) catch {}; // keep the parse alive so the borrowed slices stay valid
    }

    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    }.lt);

    const Res = struct { doc_id: []const u8, tile: i64, image: []const u8, score: u32, excerpt: []const u8 };
    const top = @min(hits.items.len, @as(usize, if (k == 0) 4 else k));
    var results: std.ArrayListUnmanaged(Res) = .empty;
    defer results.deinit(gpa);
    for (hits.items[0..top]) |h| {
        results.append(gpa, .{ .doc_id = h.doc, .tile = h.tile, .image = h.image, .score = h.score, .excerpt = h.excerpt }) catch break;
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .count = results.items.len, .results = results.items }, .{}) catch dupe(gpa, "oom");
}
