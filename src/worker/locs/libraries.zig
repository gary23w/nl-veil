//! The SOURCE ATLAS — curated, compiled-in seed locations for knowledge domains.
//!
//! WHY THIS EXISTS: a small-parameter model has no reliable "coding weights" — it cannot recall the Python
//! stdlib or Rust's module rules from its own parameters, so its knowledge floor is whatever the hive can
//! ACQUIRE. Acquisition through a bare DDG search is the weak link (ranking is poor and the right page is
//! often not in the first screen — measured in crawl.zig's search lane). The atlas removes the WHERE
//! problem for the domains that recur: canonical, curl-friendly documentation roots, compiled into the
//! binary so an offline-built device still knows exactly where to go the moment it has a link.
//!
//! WHAT THIS IS NOT: not a routing switch and not a replacement for search. The engine's control flow is
//! unchanged — the gap-auditor names what's missing, scouts research it, admission still requires a
//! verbatim page-span quote, and a source only EARNS trust when its note lands in a builder's file. The
//! atlas is a PRIOR: it seeds where to look first, ranked by a general word-match over the live gap/goal
//! text; web_search remains first-class for everything the atlas doesn't cover (and for tasks — books,
//! automation, live events — where curated references are the wrong tool entirely).
const std = @import("std");

pub const Kind = enum { reference, tutorial, spec, cookbook, index };

pub const Loc = struct {
    name: []const u8, // short domain label, shown in the directive block
    tags: []const []const u8, // word-bounded match keys against gap/goal text (multi-word tags allowed)
    seeds: []const []const u8, // canonical entry urls — DOC ROOTS, not homepages; static/curl-friendly only
    kind: Kind = .reference,
    depth: u8 = 2, // suggested crawl depth from a seed
    trust: f32 = 1.0, // ranking prior only — LEARNED application-trust decides what survives
};

/// Curation rules: (1) official documentation first; (2) the url must serve real HTML to curl (no
/// JS-walled apps); (3) doc roots over homepages so depth-2 crawls land on content; (4) tags must survive
/// word-bounded matching — never a tag that is a common English word ("go", "c") — use "golang",
/// "c language". A bare plural in the text still hits its singular tag (trailing-'s' tolerance).
pub const ATLAS = [_]Loc{
    .{ .name = "python", .tags = &.{ "python", "pytest", "cpython", "pip" }, .seeds = &.{ "https://docs.python.org/3/library/", "https://docs.python.org/3/tutorial/", "https://docs.pytest.org/en/stable/" } },
    .{ .name = "rust", .tags = &.{ "rust", "cargo", "borrow checker", "rustc" }, .seeds = &.{ "https://doc.rust-lang.org/std/", "https://doc.rust-lang.org/book/", "https://doc.rust-lang.org/rust-by-example/" } },
    .{ .name = "ruby", .tags = &.{ "ruby", "rails", "rubygem" }, .seeds = &.{ "https://ruby-doc.org/core/", "https://ruby-doc.org/stdlib/", "https://guides.rubyonrails.org/" } },
    .{ .name = "golang", .tags = &.{ "golang", "goroutine", "go module", "go stdlib" }, .seeds = &.{ "https://go.dev/doc/", "https://pkg.go.dev/std", "https://go.dev/ref/spec" } },
    .{ .name = "javascript", .tags = &.{ "javascript", "typescript", "node.js", "nodejs", "npm" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/JavaScript", "https://nodejs.org/api/" } },
    .{ .name = "web-platform", .tags = &.{ "html", "css", "dom", "frontend" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/HTML", "https://developer.mozilla.org/en-US/docs/Web/CSS" } },
    .{ .name = "http-rest", .tags = &.{ "http", "rest api", "endpoint", "cookie", "cors", "websocket" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/HTTP", "https://www.rfc-editor.org/rfc/rfc9110.html" }, .kind = .spec },
    .{ .name = "sql-sqlite", .tags = &.{ "sql", "sqlite", "database schema" }, .seeds = &.{ "https://sqlite.org/lang.html", "https://sqlite.org/docs.html" } },
    .{ .name = "c-cpp", .tags = &.{ "cpp", "c language", "c standard library", "clang" }, .seeds = &.{"https://en.cppreference.com/w/"} },
    .{ .name = "zig", .tags = &.{ "zig", "comptime" }, .seeds = &.{ "https://ziglang.org/documentation/master/", "https://ziglang.org/documentation/master/std/" } },
    .{ .name = "algorithms", .tags = &.{ "algorithm", "sorting", "complexity", "big-o", "dynamic programming" }, .seeds = &.{ "https://en.wikipedia.org/wiki/List_of_algorithms", "https://en.wikipedia.org/wiki/Analysis_of_algorithms" }, .kind = .index, .trust = 0.8 },
    .{ .name = "data-structures", .tags = &.{ "data structure", "hash table", "binary tree", "linked list", "b-tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/List_of_data_structures"}, .kind = .index, .trust = 0.8 },
    .{ .name = "software-design", .tags = &.{ "design pattern", "software architecture", "software design", "refactoring" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Software_design_pattern", "https://refactoring.guru/design-patterns" }, .kind = .cookbook, .trust = 0.8 },
    .{ .name = "security", .tags = &.{ "security", "authentication", "password hashing", "session token", "tls", "owasp" }, .seeds = &.{ "https://cheatsheetseries.owasp.org/", "https://en.wikipedia.org/wiki/PBKDF2" }, .kind = .cookbook, .trust = 0.9 },
    .{ .name = "git", .tags = &.{ "git", "merge conflict", "version control" }, .seeds = &.{"https://git-scm.com/docs"} },
    .{ .name = "shell-linux", .tags = &.{ "bash", "shell script", "linux command", "posix" }, .seeds = &.{ "https://www.gnu.org/software/bash/manual/bash.html", "https://man7.org/linux/man-pages/" } },
    .{ .name = "regex", .tags = &.{ "regex", "regular expression" }, .seeds = &.{"https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_expressions"} },
};

/// Case-insensitive word-bounded hit, with trailing-'s' tolerance so "algorithms" reaches tag "algorithm".
/// Word-bounding is load-bearing: "rust" must never fire inside "trust", "ruby" not inside "rubytest".
fn wordHit(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or text.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (!std.ascii.startsWithIgnoreCase(text[i..], needle)) continue;
        if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
        var after = i + needle.len;
        if (after < text.len and (text[after] == 's' or text[after] == 'S')) after += 1; // plural tolerance
        if (after < text.len and std.ascii.isAlphanumeric(text[after])) continue;
        return true;
    }
    return false;
}

const Scored = struct { loc: *const Loc, score: f32 };

/// Rank atlas entries against free text (gap report + goal). Score = word-bounded tag hits × the entry's
/// trust prior. Returns the number of matches written into `out`, best first. Pure and allocation-free —
/// callable from any hot path.
pub fn match(text: []const u8, out: []*const Loc) usize {
    var scored: [ATLAS.len]Scored = undefined;
    var n: usize = 0;
    for (&ATLAS) |*loc| {
        var hits: f32 = 0;
        for (loc.tags) |t| {
            if (wordHit(text, t)) hits += 1;
        }
        if (hits > 0) {
            scored[n] = .{ .loc = loc, .score = hits * loc.trust };
            n += 1;
        }
    }
    // tiny N: insertion sort, stable (earlier atlas entries win ties)
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = scored[i];
        var j = i;
        while (j > 0 and scored[j - 1].score < key.score) : (j -= 1) scored[j] = scored[j - 1];
        scored[j] = key;
    }
    const k = @min(n, out.len);
    for (0..k) |x| out[x] = scored[x].loc;
    return k;
}

/// The "CANONICAL SOURCES" block appended to a research directive: the top matched domains with their seed
/// urls, framed as look-here-FIRST (search stays the fallback and stays first-class for everything else).
/// "" when nothing matches — the caller appends nothing and the directive reads exactly as before.
pub fn sourcesBlock(gpa: std.mem.Allocator, text: []const u8, max_locs: usize) []const u8 {
    var top: [3]*const Loc = undefined;
    const n = match(text, top[0..@min(max_locs, top.len)]);
    if (n == 0) return "";
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    b.appendSlice(gpa, " CANONICAL SOURCES for this domain (curated — web_fetch/deep_crawl these FIRST; use web_search only when they don't answer or the topic is outside them): ") catch {};
    for (0..n) |i| {
        if (i > 0) b.appendSlice(gpa, " | ") catch {};
        b.append(gpa, '[') catch {};
        b.appendSlice(gpa, top[i].name) catch {};
        b.appendSlice(gpa, "] ") catch {};
        for (top[i].seeds, 0..) |s, si| {
            if (si > 0) b.append(gpa, ' ') catch {};
            b.appendSlice(gpa, s) catch {};
        }
    }
    return gpa.dupe(u8, b.items) catch "";
}

test "atlas match: word-bounded domain routing — rust never fires inside trust" {
    var top: [3]*const Loc = undefined;
    const n = match("Build a REST API in Rust with cargo and integration tests", &top);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqualStrings("rust", top[0].name); // 2 tag hits × 1.0 beats http-rest's 1 hit
    // "trust the process, adjust the gain" must not look like Rust
    var t2: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("trust the process, adjust the gain", &t2));
}

test "atlas match: plural tolerance + multi-domain + no-match stays empty" {
    var top: [3]*const Loc = undefined;
    const n = match("implement sorting algorithms in Python", &top);
    try std.testing.expect(n >= 2); // python + algorithms both matched
    var names_buf: [3][]const u8 = undefined;
    for (0..n) |i| names_buf[i] = top[i].name;
    var saw_py = false;
    var saw_algo = false;
    for (names_buf[0..n]) |nm| {
        if (std.mem.eql(u8, nm, "python")) saw_py = true;
        if (std.mem.eql(u8, nm, "algorithms")) saw_algo = true;
    }
    try std.testing.expect(saw_py and saw_algo);
    var t2: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("bake a chocolate cake for the party", &t2));
}

test "sourcesBlock: renders top domains with seeds, empty for unmatched text" {
    const gpa = std.testing.allocator;
    const blk = sourcesBlock(gpa, "PBKDF2 password hashing and session token auth in Python", 3);
    defer if (blk.len > 0) gpa.free(@constCast(blk));
    try std.testing.expect(std.mem.indexOf(u8, blk, "docs.python.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk, "cheatsheetseries.owasp.org") != null);
    const none = sourcesBlock(gpa, "narrate a short story about winter", 3);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
