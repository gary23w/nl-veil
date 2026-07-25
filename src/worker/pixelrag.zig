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
const ocr = @import("ocr.zig");
const llm = @import("llm.zig");
const osc = @import("oscillation.zig");
const Mem = osc.Mem;

const log = std.log.scoped(.pixelrag);

/// Instruction for the text-only fallback (used ONLY on a machine with no built-in OS OCR — never on Win/macOS).
/// Kept pure-transcription to match the user's "vision-as-text, no visual description" choice: it acts as an OCR
/// stand-in, not an image describer.
const VISION_PROMPT = "Act as an OCR engine. Transcribe ALL text visible in this image, verbatim and in reading order. Output only the transcribed text — no description of the image, no preamble, no markdown fences. If there is no readable text, output nothing.";

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

/// Sanitize an explicit doc_id, or derive a stable one from the URL host + a hash when none is given. Owned —
/// EVERY caller frees it, so the out-of-memory fallback must be the zero-length slice (Allocator.free returns
/// early on len 0). A non-empty literal here is not an allocation, and freeing it is an invalid free handed
/// straight to the allocator — the same contract dupe() above already keeps.
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
        if (ok) return gpa.dupe(u8, t) catch @constCast("");
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
    return std.fmt.allocPrint(gpa, "{s}-{x}", .{ if (hb.items.len > 0) hb.items else "page", h & 0xffffff }) catch @constCast("");
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

/// BROWSER-FREE image ingest: a dropped/pasted raster image has no DOM, so it can't render into tiles. Instead
/// OCR it (ocr.extractImageText — the OS OCR engine; vision-as-text, no vision model sees pixels) and feed the
/// extracted text through the SAME indexOne primitive the browser path uses. The neuron-db fact + .pixelrag
/// manifest line are written exactly as a rendered tile's would be, so pixel_search retrieves the attachment with
/// ZERO retrieval-side changes. Returns the extracted text (caller frees; "" when OCR yielded nothing / is
/// unavailable). The tile PNG is always written to disk, so the image is present as an (image-only) tile even
/// when it carried no readable text.
/// Ingest a raster image as a pixel-RAG document, browser-free: OCR its text (OS-native → vision-model fallback),
/// write the tile PNG, and index it via the SAME indexOne primitive a browser tile uses (so pixel_search finds
/// it with zero retrieval changes). base_url/key/model are the turn's provider, used ONLY for the vision-model
/// fallback when the OS has no built-in OCR (pass model="" to disable the fallback). Returns the extracted text.
pub fn ingestImage(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, run_dir: []const u8, mem: Mem, doc_id_in: []const u8, png_bytes: []const u8, base_url: []const u8, key: []const u8, model: []const u8) []u8 {
    // Stable, filesystem-safe doc id derived from the image bytes ("attach-<8hex>") unless the caller named one —
    // re-attaching the same image reuses its doc instead of piling duplicates into the index. resolveDocId
    // sanitizes/validates; a synthetic hash string doubles as its url-derive fallback.
    var idbuf: [32]u8 = undefined;
    const h32: u32 = @truncate(std.hash.Wyhash.hash(0, png_bytes));
    const synth = std.fmt.bufPrint(&idbuf, "attach-{x:0>8}", .{h32}) catch "attach";
    const chosen = if (std.mem.trim(u8, doc_id_in, " \r\n\t").len > 0) doc_id_in else synth;
    const doc_id = resolveDocId(gpa, chosen, synth);
    defer gpa.free(doc_id);

    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/{s}", .{ run_dir, doc_id }) catch return dupe(gpa, "");
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};

    // Write the tile PNG to its canonical path first (indexOne writes the identical file, but OCR needs it on
    // disk BEFORE indexing so it can read an ABSOLUTE path — the WinRT shim resolves relative paths against the
    // server's CWD, not this run dir, so an absolute path is mandatory).
    const img_abs = std.fmt.allocPrint(gpa, "{s}/tile_0.png", .{dir}) catch return dupe(gpa, "");
    defer gpa.free(img_abs);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = img_abs, .data = png_bytes }) catch {};

    // OS-NATIVE OCR first (Windows.Media.Ocr / macOS Vision — free, offline, private).
    var text: []u8 = ocr.extractImageText(gpa, io, env, run_dir, img_abs);
    // UNIVERSAL FALLBACK: no built-in OCR (Linux, or a box missing the engine) → ask a vision-capable model to
    // transcribe the image. Only when the OS path produced nothing AND a provider/model is configured. The image
    // itself is never persisted to the model — only the returned text grounds the chat, so it stays vision-as-text.
    if (std.mem.trim(u8, text, " \r\n\t").len == 0 and model.len > 0) {
        gpa.free(text);
        const r = llm.visionExtract(gpa, io, run_dir, "vision", base_url, key, model, png_bytes, VISION_PROMPT, 1200);
        text = if (r.ok) r.content else blk: {
            gpa.free(r.content); // !ok content is an error message — never index it AS the image's text
            break :blk dupe(gpa, "");
        };
    }
    defer gpa.free(text);

    var manifest_add: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest_add.deinit(gpa);
    var indexed: u32 = 0;
    // Same call shape as ingest()'s tile loop: writes the tile PNG, stores the band-text fact in neuron-db, and
    // appends the manifest line. On empty text it early-returns after writing the (image-only) tile.
    _ = indexOne(gpa, io, run_dir, mem, doc_id, 0, png_bytes, text, &manifest_add, &indexed);
    if (manifest_add.items.len > 0) appendManifest(gpa, io, run_dir, manifest_add.items);
    log.info("ingestImage {s}: {d} indexed, {d} chars", .{ doc_id, indexed, text.len });
    return dupe(gpa, text);
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

const RCResp = struct { ok: bool = false, url: []const u8 = "", tiles: []const RTile = &.{}, @"error": []const u8 = "" };

/// Snapshot the browser's CURRENT page — NO navigation, so the live post-interaction state (the logged-in
/// feed, the open modal, the just-submitted form's result) is tiled and indexed exactly as it stands. The
/// verify half of browser-driven web-app testing: interact with browser_*, then capture, then pixel_search /
/// read the tiles. Mirrors ingest's daemon/in-process split; each capture gets its own doc generation
/// (suffix) unless the caller names a doc_id, so successive snapshots stay distinguishable.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, run_dir: []const u8, mem: Mem, doc_id_in: []const u8, use_daemon: bool) []u8 {
    var url_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer url_buf.deinit(gpa);
    var indexed: u32 = 0;
    var total_chars: usize = 0;
    var tile_count: usize = 0;
    var manifest_add: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest_add.deinit(gpa);
    var tmp_doc: [64]u8 = undefined;
    var doc_id: []const u8 = std.mem.trim(u8, doc_id_in, " \r\n\t");

    if (use_daemon) {
        const params = std.fmt.allocPrint(gpa, "{{\"tile_h\":{d},\"max_tiles\":{d}}}", .{ TILE_H, MAX_TILES }) catch return dupe(gpa, "oom");
        defer gpa.free(params);
        const resp = browser_host.forward(gpa, io, env, run_dir, "rendertilescurrent", params);
        defer gpa.free(resp);
        const parsed = std.json.parseFromSlice(RCResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch
            return std.fmt.allocPrint(gpa, "pixel_capture render failed: {s}", .{clip(resp, 200)}) catch dupe(gpa, "render failed");
        defer parsed.deinit();
        if (!parsed.value.ok) {
            // A long-lived local-host daemon that predates this action answers "unknown action" — say so usefully.
            if (std.mem.indexOf(u8, resp, "unknown action") != null)
                return dupe(gpa, "pixel_capture: the local-host browser daemon is an older build without this action — restart the daemon (quit + reopen the desk, or kill the veil local-host process) and retry");
            return std.fmt.allocPrint(gpa, "pixel_capture render failed: {s}", .{clip(resp, 200)}) catch dupe(gpa, "render failed");
        }
        url_buf.appendSlice(gpa, parsed.value.url) catch {};
        doc_id = captureDocId(gpa, io, &tmp_doc, doc_id, url_buf.items);
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
        const snap = browser_mgr.renderTilesCurrent(gpa, io, env, run_dir, TILE_H, MAX_TILES) catch |e|
            return std.fmt.allocPrint(gpa, "pixel_capture failed to render: {s}", .{@errorName(e)}) catch dupe(gpa, "render failed");
        defer browser_mgr.freeSnapshot(gpa, snap);
        url_buf.appendSlice(gpa, snap.url) catch {};
        doc_id = captureDocId(gpa, io, &tmp_doc, doc_id, url_buf.items);
        tile_count = snap.tiles.len;
        for (snap.tiles) |t| total_chars += indexOne(gpa, io, run_dir, mem, doc_id, t.index, t.png, t.text, &manifest_add, &indexed);
    }

    // evaluate() may hand the href back as a quoted JSON string — normalize for the blank-page check + report
    const url = std.mem.trim(u8, url_buf.items, " \"\r\n\t");
    if (url.len == 0 or std.mem.startsWith(u8, url, "about:blank"))
        return dupe(gpa, "pixel_capture: no page is open in the browser — browser_navigate somewhere (and interact) first, THEN capture the state you want to verify");

    if (manifest_add.items.len > 0) appendManifest(gpa, io, run_dir, manifest_add.items);
    log.info("pixel_capture {s}: {d} tiles, {d} indexed of {s} (daemon={})", .{ doc_id, tile_count, indexed, clip(url, 120), use_daemon });
    const url_lit = std.json.Stringify.valueAlloc(gpa, url, .{}) catch (gpa.dupe(u8, "\"\"") catch return dupe(gpa, "captured"));
    defer gpa.free(url_lit);
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"doc_id\":\"{s}\",\"url\":{s},\"tiles\":{d},\"indexed\":{d},\"chars\":{d},\"note\":\"snapshot of the LIVE page state (nothing was reloaded) — retrieve with pixel_search, or read the tile images under .pixelrag/{s}/\"}}", .{ doc_id, url_lit, tile_count, indexed, total_chars, doc_id }) catch dupe(gpa, "captured");
}

/// The doc id for one capture: the caller's explicit id verbatim, else the url-derived base plus a short
/// random generation suffix — successive captures of the same page (a test loop) must not collapse into one
/// document, or stale states would shadow fresh ones in search results.
fn captureDocId(gpa: std.mem.Allocator, io: std.Io, buf: *[64]u8, explicit: []const u8, url: []const u8) []const u8 {
    if (explicit.len > 0) return explicit;
    const base = resolveDocId(gpa, "", if (url.len > 0) url else "live");
    defer gpa.free(base);
    var r: [2]u8 = undefined;
    io.random(&r);
    const out = std.fmt.bufPrint(buf, "{s}-s{s}", .{ base[0..@min(base.len, 56)], std.fmt.bytesToHex(r, .lower) }) catch return "live-capture";
    return out;
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

// =====================================================================================================
// tests — the ingest→index→retrieve spine, with no browser, no OCR engine and no datastore.
//
// What is covered: the doc-id derivation (it becomes a DIRECTORY name, so it is also a path-safety
// boundary), the fact sanitizer, indexOne's tile→manifest-line record, and search()'s query→tile
// mapping. What is not: ingest/ingestImage/capture, whose first act is to render or OCR — they need a
// live Chromium or an OS OCR engine, and there is nothing honest to assert about them here.
//
// indexOne also calls mem.observe(), which shells out to the neuron binary. These tests point Mem at a
// path that does not exist, so observe() returns 0 — and that is not a hidden dependency being faked
// away: search() reads the per-run `.pixelrag/index.jsonl` manifest, never neuron-db, so the retrieval
// half is genuinely independent of the store. The manifest is what is asserted throughout.
// =====================================================================================================

const testing = std.testing;

/// Index `texts` as tiles 0..n-1 of `doc` exactly the way ingest()'s tile loop does, then flush the
/// manifest — so the retrieval assertions run against records the REAL writer produced, not hand-rolled
/// JSON that could agree with a broken reader.
fn seedTiles(io: std.Io, root: []const u8, mem: Mem, doc: []const u8, texts: []const []const u8) !u32 {
    const gpa = testing.allocator;
    const dir = try std.fmt.allocPrint(gpa, "{s}/.pixelrag/{s}", .{ root, doc });
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    var add: std.ArrayListUnmanaged(u8) = .empty;
    defer add.deinit(gpa);
    var indexed: u32 = 0;
    for (texts, 0..) |t, i| _ = indexOne(gpa, io, root, mem, doc, @intCast(i), "\x89PNG\r\n fake tile bytes", t, &add, &indexed);
    if (add.items.len > 0) appendManifest(gpa, io, root, add.items);
    return indexed;
}

const SearchRes = struct { doc_id: []const u8 = "", tile: i64 = 0, image: []const u8 = "", score: u32 = 0, excerpt: []const u8 = "" };
const SearchOut = struct { ok: bool = false, count: usize = 0, results: []const SearchRes = &.{}, note: []const u8 = "" };

fn runSearch(io: std.Io, root: []const u8, query: []const u8, k: u32) !std.json.Parsed(SearchOut) {
    const gpa = testing.allocator;
    const raw = search(gpa, io, root, query, k);
    defer gpa.free(raw);
    // .alloc_always: the default lets unescaped strings borrow `raw`, which dies at this return.
    return std.json.parseFromSlice(SearchOut, gpa, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn isDocIdSafe(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) return false;
    }
    return true;
}

test "sanitizeLine keeps a tile's fact on ONE line: control bytes become spaces and runs collapse" {
    const gpa = testing.allocator;
    // neuron-db's store is newline-delimited, so a single raw newline in a tile's band text would shred
    // one tile into a row of meaningless fragments (the failure that motivated cleanFactInto upstream).
    const got = try sanitizeLine(gpa, "  Buy\tnow\r\nfor  $5\n\n\nToday  ");
    defer gpa.free(got);
    for (got) |c| try testing.expect(c >= 0x20);
    try testing.expect(std.mem.indexOf(u8, got, "  ") == null);
    try testing.expectEqualStrings(" Buy now for $5 Today ", got); // words survive, in order

    const empty = try sanitizeLine(gpa, "");
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const all_control = try sanitizeLine(gpa, "\n\r\n\t\x00\x1f");
    defer gpa.free(all_control);
    try testing.expectEqualStrings(" ", all_control); // a whole run of control bytes collapses to one space
}

test "resolveDocId keeps a caller's id only while it stays a safe file name" {
    const gpa = testing.allocator;
    const url = "https://example.com/a/b?q=1";
    // The id is interpolated straight into `{run_dir}/.pixelrag/{doc}` and into the img path recorded in
    // the manifest, so anything that is not [A-Za-z0-9_-] must be refused rather than sanitized halfway.
    for ([_][]const u8{ "doc", "My-Doc_9", "  padded  " }) |ok| {
        const got = resolveDocId(gpa, ok, url);
        defer gpa.free(got);
        try testing.expectEqualStrings(std.mem.trim(u8, ok, " \r\n\t"), got);
    }

    const derived = resolveDocId(gpa, "", url);
    defer gpa.free(derived);

    var long: [49]u8 = @splat('a');
    const refused = [_][]const u8{
        "../../etc/passwd", "a/b",   "..",        "a b",    "a.b",
        "tile\n0",          "héllo", "C:\\evil",  "q?x",    "",
        "   ",              &long, // 49 chars: one past the 48-byte ceiling
    };
    for (refused) |bad| {
        const got = resolveDocId(gpa, bad, url);
        defer gpa.free(got);
        try testing.expect(isDocIdSafe(got));
        try testing.expectEqualStrings(derived, got); // fell through to the url-derived id, every time
    }

    // ...and 48 is accepted: the ceiling is a limit, not an off-by-one.
    const at_limit: [48]u8 = @splat('a');
    const kept = resolveDocId(gpa, &at_limit, url);
    defer gpa.free(kept);
    try testing.expectEqualStrings(&at_limit, kept);
}

test "resolveDocId derives a stable id per url, distinct for two pages on the SAME host" {
    const gpa = testing.allocator;
    // Stability is what lets a re-ingest of the same page reuse its doc instead of piling duplicates
    // into the index; distinctness is what stops two pages of one site from collapsing into one doc.
    const a1 = resolveDocId(gpa, "", "https://example.com/pricing");
    defer gpa.free(a1);
    const a2 = resolveDocId(gpa, "", "https://example.com/pricing");
    defer gpa.free(a2);
    const b = resolveDocId(gpa, "", "https://example.com/docs");
    defer gpa.free(b);
    try testing.expectEqualStrings(a1, a2);
    try testing.expect(!std.mem.eql(u8, a1, b));
    try testing.expect(std.mem.startsWith(u8, a1, "examplecom-") and std.mem.startsWith(u8, b, "examplecom-"));

    // the host contributes at most 24 alnum bytes, and the hash tail at most 6 (h & 0xffffff)
    const long_host = resolveDocId(gpa, "", "https://aaaa-bbbb.cccc-dddd.eeee-ffff.gggg.example.com/x");
    defer gpa.free(long_host);
    const dash = std.mem.lastIndexOfScalar(u8, long_host, '-').?;
    try testing.expectEqual(@as(usize, 24), dash);
    try testing.expect(long_host.len - dash - 1 <= 6);
    try testing.expect(isDocIdSafe(long_host));

    // a url with no alnum host at all still yields a usable directory name
    const no_host = resolveDocId(gpa, "", "file:///c:/tmp/page.html");
    defer gpa.free(no_host);
    try testing.expect(std.mem.startsWith(u8, no_host, "page-"));
    try testing.expect(isDocIdSafe(no_host));
}

test "the OOM fallbacks return a slice the caller can free — every caller frees the doc id" {
    // ingest, ingestImage and capture all `defer gpa.free(doc_id)`. An out-of-memory fallback that is a
    // NON-EMPTY string literal is not an allocation, so freeing it is an invalid free handed straight to
    // the allocator. Allocator.free returns early on a zero-length slice, which is exactly why dupe()'s
    // fallback is "" — resolveDocId has to hold the same contract.
    const fa = testing.failing_allocator;
    try testing.expectEqual(@as(usize, 0), dupe(fa, "anything").len);
    try testing.expectEqual(@as(usize, 0), resolveDocId(fa, "already-safe", "https://example.com/").len);
    try testing.expectEqual(@as(usize, 0), resolveDocId(fa, "", "https://example.com/").len);
}

test "indexOne records the tile at exactly the path it wrote the PNG to" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-index-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag/shop", .default_dir) catch {};

    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");
    var add: std.ArrayListUnmanaged(u8) = .empty;
    defer add.deinit(gpa);
    var indexed: u32 = 0;
    const png = "\x89PNG\r\n\x1a\n fake tile bytes";
    const text = "Order total\n42 dollars";
    try testing.expectEqual(text.len, indexOne(gpa, io, root, mem, "shop", 3, png, text, &add, &indexed));
    try testing.expectEqual(@as(u32, 1), indexed);

    const parsed = try std.json.parseFromSlice(Entry, gpa, std.mem.trim(u8, add.items, " \r\n"), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("shop", parsed.value.doc);
    try testing.expectEqual(@as(i64, 3), parsed.value.tile);
    try testing.expectEqualStrings(".pixelrag/shop/tile_3.png", parsed.value.img);
    try testing.expectEqualStrings("Order total 42 dollars", parsed.value.text); // sanitized, one line

    // the recorded path is the path the bytes are actually at — this is the whole key derivation, and a
    // search hit that names a file nobody wrote is a dead result in the model's hands.
    const abs = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, parsed.value.img });
    defer gpa.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualSlices(u8, png, on_disk);
}

test "indexOne on a text-free tile still writes the image but adds no fact and no manifest line" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-blank-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag/img", .default_dir) catch {};

    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");
    var add: std.ArrayListUnmanaged(u8) = .empty;
    defer add.deinit(gpa);
    var indexed: u32 = 0;
    // A screenshot with no readable text (a chart, a photo) is the documented image-only tile: the PNG
    // must still land on disk so the tile is present, while the index gains nothing to retrieve.
    try testing.expectEqual(@as(usize, 0), indexOne(gpa, io, root, mem, "img", 0, "PNGBYTES", "  \r\n\t ", &add, &indexed));
    try testing.expectEqual(@as(u32, 0), indexed);
    try testing.expectEqual(@as(usize, 0), add.items.len);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/.pixelrag/img/tile_0.png", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("PNGBYTES", on_disk);

    // one printable byte is enough to make it a retrievable tile
    try testing.expectEqual(@as(usize, 1), indexOne(gpa, io, root, mem, "img", 1, "PNGBYTES", " x ", &add, &indexed));
    try testing.expectEqual(@as(u32, 1), indexed);
}

test "search maps a query to the tiles whose band text carries it, ranked by DISTINCT stem hits" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-search-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");

    try testing.expectEqual(@as(u32, 3), try seedTiles(io, root, mem, "shop", &.{
        "Header nav Home About Contact", // tile 0 — no query stem
        "Checkout button under the price table", // tile 1 — checkout, button, price
        "The price list only", // tile 2 — price
    }));

    // "price" appears twice and once capitalised: the score is DISTINCT stems present, so it counts once.
    // "of" is under the 3-byte floor and is not a stem at all.
    var out = try runSearch(io, root, "PRICE of checkout button price", 0);
    defer out.deinit();
    try testing.expect(out.value.ok);
    try testing.expectEqual(@as(usize, 2), out.value.count); // the header tile matched nothing and is absent
    try testing.expectEqual(@as(usize, 2), out.value.results.len);
    try testing.expectEqual(@as(u32, 3), out.value.results[0].score);
    try testing.expectEqual(@as(i64, 1), out.value.results[0].tile);
    try testing.expectEqualStrings(".pixelrag/shop/tile_1.png", out.value.results[0].image);
    try testing.expectEqualStrings("shop", out.value.results[0].doc_id);
    try testing.expectEqual(@as(u32, 1), out.value.results[1].score); // ranked below, not dropped
    try testing.expectEqual(@as(i64, 2), out.value.results[1].tile);
}

test "search: a query of only sub-3-byte tokens matches NOTHING rather than everything" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-shorttok-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");
    _ = try seedTiles(io, root, mem, "doc", &.{ "alpha beta", "gamma delta" });

    // Zero stems must score zero on every tile. The dangerous alternative — an empty stem set matching
    // every line — would answer any junk query with the whole corpus.
    var none = try runSearch(io, root, "a is of to", 0);
    defer none.deinit();
    try testing.expect(none.value.ok);
    try testing.expectEqual(@as(usize, 0), none.value.count);

    var punct = try runSearch(io, root, "...,;:!?()[]{}\"'/\\-_", 0);
    defer punct.deinit();
    try testing.expectEqual(@as(usize, 0), punct.value.count);
}

test "search: a 40-byte token is the widest stem the buffer holds, and only 24 stems are ever weighed" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-stemcap-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");

    const w40: [40]u8 = @splat('w'); // exactly fills one [40]u8 stem slot — one more would smash the next
    const w41: [41]u8 = @splat('v');
    const tile = try std.fmt.allocPrint(gpa, "prefix {s} middle {s} suffix", .{ &w40, &w41 });
    defer gpa.free(tile);
    _ = try seedTiles(io, root, mem, "cap", &.{tile});

    var wide = try runSearch(io, root, &w40, 0);
    defer wide.deinit();
    try testing.expectEqual(@as(usize, 1), wide.value.count);
    try testing.expectEqual(@as(u32, 1), wide.value.results[0].score);

    var too_wide = try runSearch(io, root, &w41, 0);
    defer too_wide.deinit();
    try testing.expectEqual(@as(usize, 0), too_wide.value.count); // dropped as a stem, so it can never hit

    // the 25th distinct stem is past the bounded stem table and is never weighed
    var q: std.ArrayListUnmanaged(u8) = .empty;
    defer q.deinit(gpa);
    for (0..24) |i| try q.print(gpa, "absentword{d} ", .{i});
    try q.appendSlice(gpa, "prefix");
    var capped = try runSearch(io, root, q.items, 0);
    defer capped.deinit();
    try testing.expectEqual(@as(usize, 0), capped.value.count);
}

test "search: k=0 falls back to the module's page size, and k caps the list without reordering it" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-topk-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");
    _ = try seedTiles(io, root, mem, "many", &.{
        "widget one", "widget two", "widget three", "widget four", "widget five", "widget six",
    });

    var dflt = try runSearch(io, root, "widget", 0);
    defer dflt.deinit();
    try testing.expectEqual(@as(usize, 4), dflt.value.count); // six match; the default page is four

    var two = try runSearch(io, root, "widget", 2);
    defer two.deinit();
    try testing.expectEqual(@as(usize, 2), two.value.count);
    try testing.expectEqual(dflt.value.results[0].tile, two.value.results[0].tile);

    var all = try runSearch(io, root, "widget", 100);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 6), all.value.count); // k past the hit count is not padded
}

test "search before anything is ingested is an ok, empty answer that names the tool to call" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-empty-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // No manifest at all: the model must get a parseable empty result, not an error string it will
    // mistake for a hit and not a crash.
    var out = try runSearch(io, root, "anything at all", 0);
    defer out.deinit();
    try testing.expect(out.value.ok);
    try testing.expectEqual(@as(usize, 0), out.value.count);
    try testing.expect(std.mem.indexOf(u8, out.value.note, "pixel_ingest") != null);
}

test "a tile past MAX_TEXT is clipped mid-character yet stays retrievable, and its excerpt is bounded" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-clip-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");

    // "zebras " is 7 bytes and each 'é' is 2, so byte MAX_TEXT lands INSIDE a character — the boundary
    // where a naive clip produces a manifest line the reader cannot parse and the tile vanishes.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    defer long.deinit(gpa);
    try long.appendSlice(gpa, "zebras ");
    while (long.items.len < MAX_TEXT + 200) try long.appendSlice(gpa, "é");
    try long.appendSlice(gpa, " omegaword");
    try testing.expect((MAX_TEXT - 7) % 2 == 1); // the clip really is mid-character

    const big_dir = try std.fmt.allocPrint(gpa, "{s}/.pixelrag/big", .{root});
    defer gpa.free(big_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, big_dir, .default_dir) catch {};
    var add: std.ArrayListUnmanaged(u8) = .empty;
    defer add.deinit(gpa);
    var indexed: u32 = 0;
    // the FULL length is reported even though only MAX_TEXT bytes are stored
    try testing.expectEqual(long.items.len, indexOne(gpa, io, root, mem, "big", 0, "PNG", long.items, &add, &indexed));
    try testing.expectEqual(@as(u32, 1), indexed);
    appendManifest(gpa, io, root, add.items);

    const stored = try std.json.parseFromSlice(Entry, gpa, std.mem.trim(u8, add.items, " \r\n"), .{});
    defer stored.deinit();
    try testing.expect(stored.value.text.len <= MAX_TEXT);

    var head = try runSearch(io, root, "zebras", 0);
    defer head.deinit();
    try testing.expectEqual(@as(usize, 1), head.value.count); // survived the clip point
    try testing.expectEqual(@as(usize, 240), head.value.results[0].excerpt.len);

    var tail = try runSearch(io, root, "omegaword", 0);
    defer tail.deinit();
    try testing.expectEqual(@as(usize, 0), tail.value.count); // and everything past MAX_TEXT is gone
}

test "appendManifest grows the index: a second document never clobbers the first" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-pixelrag-append-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/.pixelrag", .default_dir) catch {};
    const mem = Mem.init(gpa, io, root ++ "/no-neuron-binary-here", root ++ "/pixels.db");

    _ = try seedTiles(io, root, mem, "first", &.{"shared keyword alpha"});
    _ = try seedTiles(io, root, mem, "second", &.{"shared keyword beta"});

    var out = try runSearch(io, root, "keyword", 0);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 2), out.value.count);
    var seen_first = false;
    var seen_second = false;
    for (out.value.results) |r| {
        if (std.mem.eql(u8, r.doc_id, "first")) seen_first = true;
        if (std.mem.eql(u8, r.doc_id, "second")) seen_second = true;
    }
    try testing.expect(seen_first and seen_second);
}

test "captureDocId: two snapshots of the same page get different ids so a stale one cannot shadow a fresh one" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const url = "https://app.example.com/dashboard?tab=2";
    const one = captureDocId(gpa, io, &b1, "", url);
    const two = captureDocId(gpa, io, &b2, "", url);
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expect(isDocIdSafe(one) and isDocIdSafe(two));
    // base + "-s" + 4 hex of generation: both derive from the same page, so they share everything but the tail
    try testing.expect(std.mem.startsWith(u8, one, "appexamplecom-"));
    try testing.expectEqualStrings(one[0 .. one.len - 4], two[0 .. two.len - 4]);
    try testing.expect(one.len <= b1.len);
    for (one[one.len - 4 ..]) |c| try testing.expect(std.ascii.isHex(c));

    // an explicit id is honoured verbatim — a caller naming its doc wants successive captures to MERGE
    var b3: [64]u8 = undefined;
    try testing.expectEqualStrings("my-run", captureDocId(gpa, io, &b3, "my-run", url));
}
