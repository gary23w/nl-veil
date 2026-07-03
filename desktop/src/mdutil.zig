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

/// Copy `src` into `dst` with inline markdown removed: **bold**/*em*/`code` markers stripped, <br> → a
/// space. Returns the byte length written. Leaves the visible text; only the syntax noise goes.
pub fn cleanInline(dst: []u8, src: []const u8) usize {
    const s = std.mem.trim(u8, src, " \t\r");
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len and w < dst.len) {
        if (s[i] == '<' and (mdstarts(s[i..], "<br>") or mdstarts(s[i..], "<br/>") or mdstarts(s[i..], "<br />"))) {
            if (w > 0 and dst[w - 1] != ' ') {
                dst[w] = ' ';
                w += 1;
            }
            const gt = std.mem.indexOfScalarPos(u8, s, i, '>') orelse break;
            i = gt + 1;
            continue;
        }
        if (s[i] == '*') {
            i += 1;
            continue;
        }
        if (s[i] == '`') {
            i += 1;
            continue;
        }
        if (s[i] == ' ' and w > 0 and dst[w - 1] == ' ') {
            i += 1; // collapse runs of spaces (e.g. left by a stripped <br> between two spaced words)
            continue;
        }
        dst[w] = s[i];
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
