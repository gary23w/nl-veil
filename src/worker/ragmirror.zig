//! LOCAL KNOWLEDGE-PACK MIRROR — serve nl-rag pack urls from a local tree instead of the network.
//!
//! The knowledge corpus (github.com/gary23w/nl-rag) is fetchable per-page over raw.githubusercontent —
//! fine online, a dead end for the offline appliance and a tax on every cold fetch. When a local copy of
//! the corpus exists (the git clone itself, a vendored `vendor/nl-rag`, or a synced `<data>/_rag`), this
//! module maps any pack url onto that tree so the ENTIRE fetch surface — engine pack prefetch, scout
//! web_fetch of INDEX/pages, deep crawls — reads from disk transparently: same urls, same callers, zero
//! network. The mirror also carries `atlas.json`, the corpus's own manifest, from which we extend the
//! compiled-in source atlas at runtime: the compiled atlas names ~600 domains; the corpus has thousands.
//!
//! Root resolution order (first tree carrying an `atlas.json` wins):
//!   1. NL_RAG_DIR (explicit override)
//!   2. <data>/_rag        (the `veil rag sync` destination)
//!   3. vendor/nl-rag      (a clone dropped into the app tree before build)
//!
//! Set-once at process start (single-threaded), read-only afterwards — no locking needed on the hot path.

const std = @import("std");
const atlas = @import("locs/atlas.zig");

pub const RAW_BASE = "https://raw.githubusercontent.com/gary23w/nl-rag/main/";

var root_buf: [512]u8 = undefined;
var root_len: usize = 0;

pub fn setRoot(p: []const u8) void {
    const n = @min(p.len, root_buf.len);
    @memcpy(root_buf[0..n], p[0..n]);
    root_len = n;
}

pub fn root() []const u8 {
    return root_buf[0..root_len];
}

pub fn active() bool {
    return root_len > 0;
}

/// Map a corpus url onto the local tree and read it. null = not a corpus url, no mirror, or the file
/// isn't mirrored (caller falls through to its normal network path). Caller frees.
pub fn resolve(io: std.Io, gpa: std.mem.Allocator, url: []const u8, limit: usize) ?[]u8 {
    if (!active() or !std.mem.startsWith(u8, url, RAW_BASE)) return null;
    const suffix = url[RAW_BASE.len..];
    // a url is attacker-adjacent input (models emit them): never let it climb out of the mirror
    if (suffix.len == 0 or std.mem.indexOf(u8, suffix, "..") != null) return null;
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root(), suffix }) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch null;
}

/// Probe the candidate roots and adopt the first that carries an atlas.json. Returns the raw manifest
/// bytes (caller frees) so the caller can build the atlas extension from the same read, or null when no
/// mirror exists anywhere.
fn detectRoot(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, data_dir: []const u8) ?[]u8 {
    var cands_buf: [3][]const u8 = undefined;
    var cands_owned: [3]bool = .{ false, false, false };
    var n: usize = 0;
    if (environ.get("NL_RAG_DIR")) |d| if (d.len > 0) {
        cands_buf[n] = d;
        n += 1;
    };
    if (data_dir.len > 0) {
        if (std.fmt.allocPrint(gpa, "{s}/_rag", .{data_dir})) |p| {
            cands_buf[n] = p;
            cands_owned[n] = true;
            n += 1;
        } else |_| {}
    }
    cands_buf[n] = "vendor/nl-rag";
    n += 1;
    defer for (0..n) |i| {
        if (cands_owned[i]) gpa.free(@constCast(cands_buf[i]));
    };
    for (0..n) |i| {
        const ap = std.fmt.allocPrint(gpa, "{s}/atlas.json", .{cands_buf[i]}) catch continue;
        defer gpa.free(ap);
        const raw = std.Io.Dir.cwd().readFileAlloc(io, ap, gpa, .limited(32 << 20)) catch continue;
        if (raw.len < 2) {
            gpa.free(raw);
            continue;
        }
        setRoot(cands_buf[i]);
        return raw;
    }
    return null;
}

const AtlasDomain = struct {
    name: []const u8 = "",
    tags: []const []const u8 = &.{},
    origin: []const u8 = "curated",
    facts: bool = false,
    files: []const []const u8 = &.{},
};
const AtlasManifest = struct { domains: []AtlasDomain = &.{} };

/// Name tokens that would false-route goals if promoted to match tags — generic words that appear in
/// hundreds of domain names ("advanced-", "-systems", "-programming"). The pack's own tags stay authoritative;
/// this only gates the EXTRA tags derived from the domain name (the fix for compound-tag vocabulary misses:
/// a goal saying "postgis" must hit the "geospatial-gis" pack even though no curated tag is the bare word).
fn genericNameToken(w: []const u8) bool {
    const generic = [_][]const u8{ "advanced", "systems", "system", "language", "languages", "programming", "engineering", "development", "deep", "more", "basics", "guide", "theory", "applied", "general", "computer", "computing", "science", "data", "tools", "books", "patterns", "methods", "analysis", "design", "model", "models", "network", "networks", "digital", "software", "hardware", "platform", "standard", "standards", "protocol", "protocols", "framework", "frameworks", "library", "libraries", "introduction", "overview", "fundamentals", "concepts", "principles", "practice", "practices", "common", "modern", "complete", "essential", "popular", "other", "misc", "extra" };
    for (generic) |g| if (std.ascii.eqlIgnoreCase(w, g)) return true;
    return false;
}

fn hasTag(tags: []const []const u8, len: usize, t: []const u8) bool {
    for (tags[0..len]) |x| if (std.ascii.eqlIgnoreCase(x, t)) return true;
    return false;
}

/// Domains the COMPILED atlas already routes (by pack directory name) — an extension entry for the same
/// pack would double-list it in directives and steal ranking from the hand-tuned entry.
fn compiledPackDomain(pack_url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, pack_url, RAW_BASE ++ "packs/")) return "";
    const rest = pack_url[(RAW_BASE ++ "packs/").len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    return rest[0..slash];
}

fn compiledCovers(domain: []const u8) bool {
    for (&atlas.ATLAS) |*loc| {
        if (loc.pack.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(compiledPackDomain(loc.pack), domain)) return true;
    }
    return false;
}

/// Build runtime atlas entries from the mirror's atlas.json: every pack the compiled atlas does NOT
/// already cover becomes matchable — its own tags, plus tags derived from the domain name so a goal can
/// hit the pack by name ("raft-consensus" matches "raft" even though the curated compound tag wouldn't).
/// Machine-grown (`origin: auto`) packs are excluded unless include_auto: that half of the corpus drifted
/// off-topic and would pollute goal routing. Allocations live for the process (freeExtension is for tests).
pub fn buildExtension(gpa: std.mem.Allocator, atlas_raw: []const u8, include_auto: bool) ![]atlas.Loc {
    const parsed = std.json.parseFromSlice(AtlasManifest, gpa, atlas_raw, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(atlas.Loc) = .empty;
    errdefer out.deinit(gpa);
    for (parsed.value.domains) |d| {
        if (d.name.len == 0 or d.name.len > 96) continue;
        if (!include_auto and !std.mem.eql(u8, d.origin, "curated")) continue;
        if (compiledCovers(d.name)) continue;
        if (out.items.len >= 6000) break;
        var tags_buf: [12][]const u8 = undefined;
        var tn: usize = 0;
        for (d.tags) |t| {
            if (tn >= 8 or t.len < 3 or t.len > 48) continue;
            if (hasTag(tags_buf[0..], tn, t)) continue;
            tags_buf[tn] = t;
            tn += 1;
        }
        // name-derived tags: the full name with hyphens as spaces, then each distinctive token
        var name_sp_buf: [96]u8 = undefined;
        var name_sp: []const u8 = "";
        if (std.mem.indexOfScalar(u8, d.name, '-') != null) {
            for (d.name, 0..) |c, i| name_sp_buf[i] = if (c == '-') ' ' else c;
            name_sp = name_sp_buf[0..d.name.len];
            if (tn < tags_buf.len and !hasTag(tags_buf[0..], tn, name_sp)) {
                tags_buf[tn] = name_sp;
                tn += 1;
            }
        } else if (tn < tags_buf.len and !hasTag(tags_buf[0..], tn, d.name)) {
            tags_buf[tn] = d.name;
            tn += 1;
        }
        var it = std.mem.tokenizeScalar(u8, d.name, '-');
        while (it.next()) |tok| {
            if (tn >= tags_buf.len) break;
            if (tok.len < 4 or genericNameToken(tok) or hasTag(tags_buf[0..], tn, tok)) continue;
            tags_buf[tn] = tok;
            tn += 1;
        }
        if (tn == 0) continue;
        const tags = try gpa.alloc([]const u8, tn);
        for (0..tn) |i| tags[i] = try gpa.dupe(u8, tags_buf[i]);
        const pack = try std.fmt.allocPrint(gpa, "{s}packs/{s}/INDEX.md", .{ RAW_BASE, d.name });
        try out.append(gpa, .{
            .name = try gpa.dupe(u8, d.name),
            .tags = tags,
            .seeds = &.{},
            .pack = pack,
            .trust = 0.7, // below every hand-tuned prior — the compiled atlas wins ties
        });
    }
    return out.toOwnedSlice(gpa);
}

pub const SyncTier = enum { atlas, facts, full };
pub const SyncStats = struct { domains: u32 = 0, files: u32 = 0, bytes: u64 = 0, missing: u32 = 0 };

fn copyPackFile(gpa: std.mem.Allocator, io: std.Io, from: []const u8, dest: []const u8, domain: []const u8, name: []const u8, st: *SyncStats) bool {
    const sp = std.fmt.allocPrint(gpa, "{s}/packs/{s}/{s}", .{ from, domain, name }) catch return false;
    defer gpa.free(sp);
    const body = std.Io.Dir.cwd().readFileAlloc(io, sp, gpa, .limited(32 << 20)) catch return false;
    defer gpa.free(body);
    const dp = std.fmt.allocPrint(gpa, "{s}/packs/{s}/{s}", .{ dest, domain, name }) catch return false;
    defer gpa.free(dp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dp, .data = body }) catch return false;
    st.files += 1;
    st.bytes += body.len;
    return true;
}

/// Copy a corpus tree (a git clone of the pack repo, or any prior mirror) into `dest` so the app carries
/// its knowledge base locally — the "download the corpus into the app before build/ship" path. Tiers:
/// `atlas` = the manifest alone (routing only), `facts` = + each pack's INDEX and distilled facts (the
/// retrieval floor), `full` = + every pack page. Machine-grown packs are excluded unless include_auto —
/// that half of the corpus drifted off-topic. Overwrites destination files, so re-sync is idempotent.
pub fn syncFrom(gpa: std.mem.Allocator, io: std.Io, from: []const u8, dest: []const u8, tier: SyncTier, include_auto: bool) !SyncStats {
    var st = SyncStats{};
    const ap = try std.fmt.allocPrint(gpa, "{s}/atlas.json", .{from});
    defer gpa.free(ap);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, ap, gpa, .limited(32 << 20)) catch return error.NoAtlasManifest;
    defer gpa.free(raw);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dest, .default_dir) catch {};
    const dap = try std.fmt.allocPrint(gpa, "{s}/atlas.json", .{dest});
    defer gpa.free(dap);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dap, .data = raw }) catch return error.WriteFailed;
    st.files += 1;
    st.bytes += raw.len;
    if (tier == .atlas) return st;
    const parsed = std.json.parseFromSlice(AtlasManifest, gpa, raw, .{ .ignore_unknown_fields = true }) catch return error.BadAtlasManifest;
    defer parsed.deinit();
    for (parsed.value.domains) |d| {
        if (d.name.len == 0 or d.name.len > 96 or std.mem.indexOf(u8, d.name, "..") != null) continue;
        if (!include_auto and !std.mem.eql(u8, d.origin, "curated")) continue;
        const ddir = std.fmt.allocPrint(gpa, "{s}/packs/{s}", .{ dest, d.name }) catch continue;
        defer gpa.free(ddir);
        _ = std.Io.Dir.cwd().createDirPathStatus(io, ddir, .default_dir) catch continue;
        var any = false;
        for ([_][]const u8{ "INDEX.md", "pack.facts" }) |bn| {
            if (copyPackFile(gpa, io, from, dest, d.name, bn, &st)) any = true;
        }
        if (tier == .full) for (d.files) |f| {
            if (f.len == 0 or std.mem.indexOf(u8, f, "..") != null or std.mem.indexOfScalar(u8, f, '/') != null) continue;
            if (copyPackFile(gpa, io, from, dest, d.name, f, &st)) any = true;
        };
        if (any) st.domains += 1 else st.missing += 1;
    }
    return st;
}

pub fn freeExtension(gpa: std.mem.Allocator, ext: []atlas.Loc) void {
    for (ext) |loc| {
        for (loc.tags) |t| gpa.free(@constCast(t));
        gpa.free(@constCast(loc.tags));
        gpa.free(@constCast(loc.name));
        gpa.free(@constCast(loc.pack));
    }
    gpa.free(ext);
}

/// One-call startup wiring: detect a mirror, adopt it as the url resolver root, and extend the source
/// atlas from its manifest. Returns true when a mirror is active. Call ONCE per process, before any
/// concurrent fetch path runs.
pub fn initAt(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, data_dir: []const u8) bool {
    const raw = detectRoot(gpa, io, environ, data_dir) orelse return false;
    defer gpa.free(raw);
    const include_auto = if (environ.get("NL_RAG_AUTO")) |v| v.len > 0 and v[0] == '1' else false;
    const ext = buildExtension(gpa, raw, include_auto) catch &.{};
    if (ext.len > 0) atlas.setExtension(ext);
    return true;
}

test "resolve maps corpus urls onto the mirror and refuses traversal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "packs/example-domain");
    try tmp.dir.writeFile(io, .{ .sub_path = "packs/example-domain/pack.facts", .data = "[src:example-domain/page] A fact.\n" });
    // testing.tmpDir lives at cwd-relative .zig-cache/tmp/<name>; resolve() reads through cwd, so a
    // relative root exercises exactly the production path shape
    var rb: [64]u8 = undefined;
    const rel = std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    const old_len = root_len;
    defer root_len = old_len;
    setRoot(rel);

    const url = RAW_BASE ++ "packs/example-domain/pack.facts";
    const body = resolve(io, gpa, url, 1 << 20) orelse return error.TestUnexpectedResult;
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "A fact.") != null);
    // missing file → null (caller falls back to network)
    try std.testing.expect(resolve(io, gpa, RAW_BASE ++ "packs/absent/pack.facts", 1 << 20) == null);
    // traversal must never escape the mirror
    try std.testing.expect(resolve(io, gpa, RAW_BASE ++ "../secret.txt", 1 << 20) == null);
    // non-corpus urls are not ours
    try std.testing.expect(resolve(io, gpa, "https://example.com/x", 1 << 20) == null);
}

test "buildExtension: curated-only default, compiled dedup, name-token tags" {
    const gpa = std.testing.allocator;
    // fictional vertical so the fixture can never collide with a compiled atlas entry (the compiled
    // table keeps growing — a real domain name here silently flips the dedup expectation)
    const raw =
        \\{"name":"nl-rag","domains":[
        \\ {"name":"python","tags":["python"],"origin":"curated","facts":true},
        \\ {"name":"basketweave-signaling","tags":["basketweave signaling","weft analysis"],"origin":"curated","facts":true},
        \\ {"name":"1915-chicago-whales-season","tags":["baseball"],"origin":"auto","facts":true}
        \\]}
    ;
    const ext = try buildExtension(gpa, raw, false);
    defer freeExtension(gpa, ext);
    // python is compiled-covered → skipped; the auto junk domain → skipped; the vertical stays
    try std.testing.expectEqual(@as(usize, 1), ext.len);
    try std.testing.expectEqualStrings("basketweave-signaling", ext[0].name);
    try std.testing.expect(ext[0].pack.len > 0);
    // its own compound tags survive AND the name tokens became matchable words
    var saw_token = false;
    var saw_compound = false;
    for (ext[0].tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, "basketweave")) saw_token = true;
        if (std.ascii.eqlIgnoreCase(t, "basketweave signaling")) saw_compound = true;
    }
    try std.testing.expect(saw_token and saw_compound);
}

test "extension entries are matchable through atlas.match" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"domains":[{"name":"basketweave-signaling","tags":["basketweave algorithm"],"origin":"curated","facts":true}]}
    ;
    const ext = try buildExtension(gpa, raw, false);
    defer freeExtension(gpa, ext);
    atlas.setExtension(ext);
    defer atlas.setExtension(&.{});
    var top: [4]*const atlas.Loc = undefined;
    const n = atlas.match("implement basketweave leader election", top[0..]);
    try std.testing.expect(n >= 1);
    var found = false;
    for (top[0..n]) |loc| if (std.mem.eql(u8, loc.name, "basketweave-signaling")) {
        found = true;
    };
    try std.testing.expect(found);
}
