//! mdutil.zig — the PURE (no-raylib) part of the chat markdown renderer: block classification + inline
//! cleanup. Kept separate from main.zig so it unit-tests standalone (main.zig links raylib and can't be
//! `zig test`ed alone). The drawing (renderMsg/renderTable) stays in main.zig and calls these.

const std = @import("std");

pub fn mdstarts(hay: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, hay, needle);
}

pub fn hasPipe(tl: []const u8) bool {
    return tl.len > 0 and std.mem.indexOfScalar(u8, tl, '|') != null;
}

/// A markdown horizontal rule: 3+ of '-', '*', or '_' (spaces allowed), nothing else.
pub fn isHr(tl: []const u8) bool {
    if (tl.len < 3) return false;
    const c = tl[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (tl) |ch| {
        if (ch == ' ') continue;
        if (ch != c) return false;
        count += 1;
    }
    return count >= 3;
}

/// The |---|:--:|---| row under a table header: only |, -, :, spaces, with at least one '-'.
pub fn isTableSep(tl: []const u8) bool {
    if (tl.len == 0 or std.mem.indexOfScalar(u8, tl, '-') == null) return false;
    for (tl) |ch| {
        if (ch != '|' and ch != '-' and ch != ':' and ch != ' ') return false;
    }
    return true;
}

/// Strip the outer pipes of a table row so a plain '|' split yields exactly the cells.
pub fn tableInner(tl: []const u8) []const u8 {
    var s = tl;
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    return s;
}

fn isAlnum(c: u8) bool {
    const l = c | 0x20;
    return (l >= 'a' and l <= 'z') or (c >= '0' and c <= '9');
}

/// Copy `src` into `dst` with inline markdown resolved to readable text:
///   [text](url) / ![alt](url) → text          (the raw url is dropped)
///   **bold** / __bold__ / *em* / _em_ / `code` → the inner text (markers stripped)
///   <br> → a space
/// Emphasis markers are stripped only when WORD-ADJACENT, so `a * b` (literal) and `file_name`
/// (snake_case) survive intact — the old version stripped every '*' and no '_', which mangled math and
/// left `_italic_`/`__bold__`/`[links](...)` showing raw (the "markdown fails" reports). Returns bytes written.
pub fn cleanInline(dst: []u8, src: []const u8) usize {
    const s = std.mem.trim(u8, src, " \t\r");
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len and w < dst.len) {
        const c = s[i];
        // <br> → space
        if (c == '<' and (mdstarts(s[i..], "<br>") or mdstarts(s[i..], "<br/>") or mdstarts(s[i..], "<br />"))) {
            if (w > 0 and dst[w - 1] != ' ') {
                dst[w] = ' ';
                w += 1;
            }
            const gt = std.mem.indexOfScalarPos(u8, s, i, '>') orelse break;
            i = gt + 1;
            continue;
        }
        // link / image: [text](url) or ![alt](url) → keep only the bracketed text
        if (c == '[' or (c == '!' and i + 1 < s.len and s[i + 1] == '[')) {
            const open = if (c == '!') i + 1 else i;
            if (std.mem.indexOfScalarPos(u8, s, open + 1, ']')) |rb| {
                if (rb + 1 < s.len and s[rb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, rb + 1, ')')) |rp| {
                        for (s[open + 1 .. rb]) |lc| {
                            if (w >= dst.len) break;
                            if (lc == '*' or lc == '`' or lc == '_') continue; // labels can carry emphasis noise
                            dst[w] = lc;
                            w += 1;
                        }
                        i = rp + 1;
                        continue;
                    }
                }
            }
            // not a well-formed link — fall through and emit '[' literally
        }
        // **bold** / __bold__ — a doubled marker is always emphasis
        if ((c == '*' or c == '_') and i + 1 < s.len and s[i + 1] == c) {
            i += 2;
            continue;
        }
        // single * / _ — strip only as emphasis (word-adjacent), never a lone "a * b" or a snake_case '_'
        if (c == '*' or c == '_') {
            const prev: u8 = if (i > 0) s[i - 1] else ' ';
            const next: u8 = if (i + 1 < s.len) s[i + 1] else ' ';
            const snake = c == '_' and isAlnum(prev) and isAlnum(next);
            if ((isAlnum(prev) or isAlnum(next)) and !snake) {
                i += 1;
                continue;
            }
        }
        // inline code marker
        if (c == '`') {
            i += 1;
            continue;
        }
        if (c == ' ' and w > 0 and dst[w - 1] == ' ') {
            i += 1; // collapse runs of spaces (e.g. left by a stripped <br>)
            continue;
        }
        dst[w] = c;
        w += 1;
        i += 1;
    }
    while (w > 0 and dst[w - 1] == ' ') w -= 1;
    return w;
}

// ---- tests ----

test "isHr recognises rules but not bullets or text" {
    try std.testing.expect(isHr("---"));
    try std.testing.expect(isHr("***"));
    try std.testing.expect(isHr("- - -"));
    try std.testing.expect(isHr("___"));
    try std.testing.expect(!isHr("--"));
    try std.testing.expect(!isHr("- item"));
    try std.testing.expect(!isHr("text"));
}

test "isTableSep matches the header separator row only" {
    try std.testing.expect(isTableSep("|---|---|"));
    try std.testing.expect(isTableSep("|:--|--:|:-:|"));
    try std.testing.expect(isTableSep("--- | ---"));
    try std.testing.expect(!isTableSep("| a | b |")); // has letters
    try std.testing.expect(!isTableSep("|||")); // no dash
}

test "tableInner strips outer pipes" {
    try std.testing.expectEqualStrings(" a | b ", tableInner("| a | b |"));
    try std.testing.expectEqualStrings("a|b", tableInner("a|b"));
}

test "cleanInline strips bold/code markers and <br>" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("bold text", b[0..cleanInline(&b, "**bold text**")]);
    try std.testing.expectEqualStrings("a code b", b[0..cleanInline(&b, "a `code` b")]);
    try std.testing.expectEqualStrings("line one line two", b[0..cleanInline(&b, "line one<br>line two")]);
    try std.testing.expectEqualStrings("line one line two", b[0..cleanInline(&b, "line one <br/> line two")]);
    try std.testing.expectEqualStrings("Overview of Iran", b[0..cleanInline(&b, "  **Overview of Iran**  ")]);
    // a realistic table cell
    try std.testing.expectEqualStrings("He secured backing. Opponents disagree.", b[0..cleanInline(&b, "He secured backing. <br>Opponents disagree.")]);
}

test "cleanInline resolves links, underscore emphasis, and keeps literals" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("See the docs for more.", b[0..cleanInline(&b, "See [the docs](https://ziglang.org/documentation) for more.")]);
    try std.testing.expectEqualStrings("this is italic here", b[0..cleanInline(&b, "this is _italic_ here")]);
    try std.testing.expectEqualStrings("Install with npm install then run.", b[0..cleanInline(&b, "Install with __npm install__ then run.")]);
    try std.testing.expectEqualStrings("bold and italic and code", b[0..cleanInline(&b, "**bold** and _italic_ and `code`")]);
    // literals must survive: a lone '*' between spaces, and snake_case underscores
    try std.testing.expectEqualStrings("Multiply a * b now", b[0..cleanInline(&b, "Multiply a * b now")]);
    try std.testing.expectEqualStrings("open file_name.txt in std_lib", b[0..cleanInline(&b, "open file_name.txt in std_lib")]);
    // an image and a malformed bracket
    try std.testing.expectEqualStrings("logo shown", b[0..cleanInline(&b, "![logo](x.png) shown")]);
    try std.testing.expectEqualStrings("[unclosed bracket", b[0..cleanInline(&b, "[unclosed bracket")]);
}

test "a full GFM table row round-trips through inner+split+clean" {
    const row = "| Date | Story | Notes |";
    var it = std.mem.splitScalar(u8, tableInner(std.mem.trim(u8, row, " ")), '|');
    var cells: [8][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |c| : (n += 1) cells[n] = std.mem.trim(u8, c, " ");
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("Date", cells[0]);
    try std.testing.expectEqualStrings("Story", cells[1]);
    try std.testing.expectEqualStrings("Notes", cells[2]);
}
