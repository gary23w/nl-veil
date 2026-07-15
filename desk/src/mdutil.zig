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

fn isAlpha(c: u8) bool {
    const l = c | 0x20;
    return l >= 'a' and l <= 'z';
}

// ---- math (LaTeX-ish -> unicode) --------------------------------------------------------------------------
// Render formulas legibly WITHOUT a LaTeX engine: strip $ / $$ delimiters, map \greek + \operators to real
// unicode (the font atlas + theme.foldAscii were extended to carry these), turn \frac{a}{b} into (a)/(b), and
// convert ^/_ scripts to unicode super/subscripts. Everything unmappable degrades to readable ASCII — never a
// raw backslash-command and never a corrupted word. All output is bounded to dst.len.

fn putB(dst: []u8, w: *usize, b: u8) void {
    if (w.* < dst.len) {
        dst[w.*] = b;
        w.* += 1;
    }
}
fn putS(dst: []u8, w: *usize, s: []const u8) void {
    for (s) |b| {
        if (w.* >= dst.len) return;
        dst[w.*] = b;
        w.* += 1;
    }
}
fn putCp(dst: []u8, w: *usize, cp: u21) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    putS(dst, w, buf[0..n]);
}

fn superCp(c: u8) ?u21 {
    return switch (c) {
        '0' => 0x2070,
        '1' => 0x00B9,
        '2' => 0x00B2,
        '3' => 0x00B3,
        '4' => 0x2074,
        '5' => 0x2075,
        '6' => 0x2076,
        '7' => 0x2077,
        '8' => 0x2078,
        '9' => 0x2079,
        '+' => 0x207A,
        '-' => 0x207B,
        '=' => 0x207C,
        '(' => 0x207D,
        ')' => 0x207E,
        'n' => 0x207F,
        'i' => 0x2071,
        else => null,
    };
}
fn subCp(c: u8) ?u21 {
    return switch (c) {
        '0' => 0x2080,
        '1' => 0x2081,
        '2' => 0x2082,
        '3' => 0x2083,
        '4' => 0x2084,
        '5' => 0x2085,
        '6' => 0x2086,
        '7' => 0x2087,
        '8' => 0x2088,
        '9' => 0x2089,
        '+' => 0x208A,
        '-' => 0x208B,
        '=' => 0x208C,
        '(' => 0x208D,
        ')' => 0x208E,
        'a' => 0x2090,
        'e' => 0x2091,
        'o' => 0x2092,
        'x' => 0x2093,
        'h' => 0x2095,
        'k' => 0x2096,
        'l' => 0x2097,
        'm' => 0x2098,
        'n' => 0x2099,
        'p' => 0x209A,
        's' => 0x209B,
        't' => 0x209C,
        'i' => 0x1D62,
        'j' => 0x2C7C,
        'r' => 0x1D63,
        'u' => 0x1D64,
        'v' => 0x1D65,
        else => null,
    };
}

const MathRepl = struct { name: []const u8, rep: []const u8 };
// A LaTeX command's WHOLE letter-run is read and looked up EXACTLY here (so "le"/"leq"/"leftarrow" never collide).
const math_macros = [_]MathRepl{
    // relations + operators
    .{ .name = "times", .rep = "\u{00D7}" },      .{ .name = "div", .rep = "\u{00F7}" },
    .{ .name = "cdot", .rep = "\u{22C5}" },       .{ .name = "cdots", .rep = "\u{22C5}\u{22C5}\u{22C5}" },
    .{ .name = "pm", .rep = "\u{00B1}" },         .{ .name = "mp", .rep = "-/+" },
    .{ .name = "leq", .rep = "\u{2264}" },        .{ .name = "le", .rep = "\u{2264}" },
    .{ .name = "geq", .rep = "\u{2265}" },        .{ .name = "ge", .rep = "\u{2265}" },
    .{ .name = "neq", .rep = "\u{2260}" },        .{ .name = "ne", .rep = "\u{2260}" },
    .{ .name = "approx", .rep = "\u{2248}" },     .{ .name = "equiv", .rep = "\u{2261}" },
    .{ .name = "propto", .rep = "\u{221D}" },     .{ .name = "sim", .rep = "~" },
    .{ .name = "infty", .rep = "\u{221E}" },      .{ .name = "partial", .rep = "\u{2202}" },
    .{ .name = "nabla", .rep = "\u{2207}" },      .{ .name = "sum", .rep = "\u{2211}" },
    .{ .name = "prod", .rep = "\u{220F}" },       .{ .name = "int", .rep = "\u{222B}" },
    .{ .name = "in", .rep = "\u{2208}" },         .{ .name = "notin", .rep = "\u{2209}" },
    .{ .name = "cup", .rep = "\u{222A}" },        .{ .name = "cap", .rep = "\u{2229}" },
    .{ .name = "to", .rep = "\u{2192}" },         .{ .name = "rightarrow", .rep = "\u{2192}" },
    .{ .name = "Rightarrow", .rep = "\u{21D2}" }, .{ .name = "implies", .rep = "\u{21D2}" },
    .{ .name = "leftarrow", .rep = "\u{2190}" },  .{ .name = "uparrow", .rep = "\u{2191}" },
    .{ .name = "downarrow", .rep = "\u{2193}" },  .{ .name = "ldots", .rep = "..." },
    .{ .name = "dots", .rep = "..." },            .{ .name = "langle", .rep = "<" },
    .{ .name = "rangle", .rep = ">" },            .{ .name = "cdotp", .rep = "\u{22C5}" },
    // greek lowercase
    .{ .name = "alpha", .rep = "\u{03B1}" },      .{ .name = "beta", .rep = "\u{03B2}" },
    .{ .name = "gamma", .rep = "\u{03B3}" },      .{ .name = "delta", .rep = "\u{03B4}" },
    .{ .name = "epsilon", .rep = "\u{03B5}" },    .{ .name = "varepsilon", .rep = "\u{03B5}" },
    .{ .name = "zeta", .rep = "\u{03B6}" },       .{ .name = "eta", .rep = "\u{03B7}" },
    .{ .name = "theta", .rep = "\u{03B8}" },      .{ .name = "vartheta", .rep = "\u{03B8}" },
    .{ .name = "iota", .rep = "\u{03B9}" },       .{ .name = "kappa", .rep = "\u{03BA}" },
    .{ .name = "lambda", .rep = "\u{03BB}" },     .{ .name = "mu", .rep = "\u{03BC}" },
    .{ .name = "nu", .rep = "\u{03BD}" },         .{ .name = "xi", .rep = "\u{03BE}" },
    .{ .name = "omicron", .rep = "\u{03BF}" },    .{ .name = "pi", .rep = "\u{03C0}" },
    .{ .name = "rho", .rep = "\u{03C1}" },        .{ .name = "sigma", .rep = "\u{03C3}" },
    .{ .name = "tau", .rep = "\u{03C4}" },        .{ .name = "upsilon", .rep = "\u{03C5}" },
    .{ .name = "phi", .rep = "\u{03C6}" },        .{ .name = "varphi", .rep = "\u{03C6}" },
    .{ .name = "chi", .rep = "\u{03C7}" },        .{ .name = "psi", .rep = "\u{03C8}" },
    .{ .name = "omega", .rep = "\u{03C9}" },
    // greek uppercase (the ones that differ from Latin letters)
         .{ .name = "Gamma", .rep = "\u{0393}" },
    .{ .name = "Delta", .rep = "\u{0394}" },      .{ .name = "Theta", .rep = "\u{0398}" },
    .{ .name = "Lambda", .rep = "\u{039B}" },     .{ .name = "Xi", .rep = "\u{039E}" },
    .{ .name = "Pi", .rep = "\u{03A0}" },         .{ .name = "Sigma", .rep = "\u{03A3}" },
    .{ .name = "Phi", .rep = "\u{03A6}" },        .{ .name = "Psi", .rep = "\u{03A8}" },
    .{ .name = "Omega", .rep = "\u{03A9}" },
    // spacing / styling macros — drop (or thin space)
         .{ .name = "left", .rep = "" },
    .{ .name = "right", .rep = "" },              .{ .name = "displaystyle", .rep = "" },
    .{ .name = "limits", .rep = "" },             .{ .name = "quad", .rep = "  " },
    .{ .name = "qquad", .rep = "    " },          .{ .name = "space", .rep = " " },
};

fn matchMacro(name: []const u8) ?[]const u8 {
    for (math_macros) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.rep;
    }
    return null;
}

const Braced = struct { inner: []const u8, next: usize };
/// s[at] must be '{'; returns the balanced brace content + the index just past the closing '}'.
fn readBraced(s: []const u8, at: usize) ?Braced {
    if (at >= s.len or s[at] != '{') return null;
    var depth: usize = 0;
    var j = at;
    while (j < s.len) : (j += 1) {
        if (s[j] == '{') {
            depth += 1;
        } else if (s[j] == '}') {
            depth -= 1;
            if (depth == 0) return .{ .inner = s[at + 1 .. j], .next = j + 1 };
        }
    }
    return null; // unbalanced — caller falls back
}

const Script = struct { arg: []const u8, next: usize };
/// Read a ^/_ script argument at s[at]: a {braced group} or a single script-able token.
fn readScript(s: []const u8, at: usize) ?Script {
    if (at >= s.len) return null;
    if (s[at] == '{') {
        if (readBraced(s, at)) |b| return .{ .arg = b.inner, .next = b.next };
        return null;
    }
    const ch = s[at];
    if (isAlnum(ch) or ch == '+' or ch == '-' or ch == '=' or ch == '(' or ch == ')') return .{ .arg = s[at .. at + 1], .next = at + 1 };
    return null;
}

/// Emit a super/subscript: unicode when every char converts, else a readable ASCII fallback (^x / (x)) that
/// never leaves a corrupting bare marker.
fn emitScript(dst: []u8, w: *usize, arg: []const u8, is_super: bool) void {
    var all = arg.len > 0;
    for (arg) |ch| {
        const cp = if (is_super) superCp(ch) else subCp(ch);
        if (cp == null) {
            all = false;
            break;
        }
    }
    if (all) {
        for (arg) |ch| putCp(dst, w, (if (is_super) superCp(ch) else subCp(ch)).?);
        return;
    }
    if (is_super) {
        if (arg.len == 1) {
            putB(dst, w, '^');
            putB(dst, w, arg[0]);
        } else {
            putS(dst, w, "^(");
            putS(dst, w, arg);
            putB(dst, w, ')');
        }
    } else if (arg.len == 1) {
        // single-char subscript index (e.g. x_q) — keep '_q'; cleanInline's snake rule preserves it verbatim.
        putB(dst, w, '_');
        putB(dst, w, arg[0]);
    } else {
        putB(dst, w, '_');
        putB(dst, w, '(');
        putS(dst, w, arg);
        putB(dst, w, ')');
    }
}

fn writeMath(dst: []u8, w: *usize, src: []const u8, depth: u8) void {
    var i: usize = 0;
    var in_math = false;
    while (i < src.len and w.* < dst.len) {
        const c = src[i];
        if (c == '$') {
            if (i + 1 < src.len and src[i + 1] == '$') { // display delimiter $$
                in_math = !in_math;
                i += 2;
                continue;
            }
            if (in_math) { // closing inline delimiter
                in_math = false;
                i += 1;
                continue;
            }
            // Opening '$' vs a currency '$': look at the whole span up to the next '$' (or end). It's MATH if the
            // span carries a math signal (\ ^ _ { }) or starts with a letter/backslash; otherwise it's currency
            // ($5, $10) and the '$' stays literal. This distinguishes "$2^{32}$" (math) from "$5 and $10" (money).
            var e = i + 1;
            while (e < src.len and src[e] != '$') e += 1;
            const span = src[i + 1 .. e];
            var mathy = false;
            for (span) |ch| {
                if (ch == '\\' or ch == '^' or ch == '_' or ch == '{' or ch == '}') {
                    mathy = true;
                    break;
                }
            }
            if (!mathy) {
                const f = std.mem.trimStart(u8, span, " ");
                if (f.len > 0 and (isAlpha(f[0]) or f[0] == '\\')) mathy = true;
            }
            if (mathy) { // opening inline delimiter
                in_math = true;
                i += 1;
                continue;
            }
            putB(dst, w, '$'); // currency etc — keep the literal '$'
            i += 1;
            continue;
        }
        if (c == '\\') {
            if (i + 1 < src.len and !isAlpha(src[i + 1])) {
                const e = src[i + 1];
                switch (e) {
                    '(', '[' => {
                        in_math = true; // \( \[ open a math span (so ^/_ inside them convert)
                    },
                    ')', ']' => {
                        in_math = false; // \) \] close it
                    },
                    ',', ';', '!', ':' => putB(dst, w, ' '), // thin-space macros
                    else => putB(dst, w, e), // \{ \} \% \& \# \_ \$ -> the literal char
                }
                i += 2;
                continue;
            }
            var j = i + 1;
            while (j < src.len and isAlpha(src[j])) j += 1;
            const name = src[i + 1 .. j];
            i = j;
            if (std.mem.eql(u8, name, "frac") and depth < 8) {
                if (i < src.len and src[i] == '{') {
                    if (readBraced(src, i)) |a| {
                        if (a.next < src.len and src[a.next] == '{') {
                            if (readBraced(src, a.next)) |b| {
                                putB(dst, w, '(');
                                writeMath(dst, w, a.inner, depth + 1);
                                putS(dst, w, ")/(");
                                writeMath(dst, w, b.inner, depth + 1);
                                putB(dst, w, ')');
                                i = b.next;
                                continue;
                            }
                        }
                        putB(dst, w, '(');
                        writeMath(dst, w, a.inner, depth + 1);
                        putB(dst, w, ')');
                        i = a.next;
                        continue;
                    }
                }
                putB(dst, w, '/');
                continue;
            }
            if (std.mem.eql(u8, name, "sqrt")) {
                putCp(dst, w, 0x221A); // √
                if (i < src.len and src[i] == '{') {
                    if (readBraced(src, i)) |a| {
                        putB(dst, w, '(');
                        writeMath(dst, w, a.inner, depth + 1);
                        putB(dst, w, ')');
                        i = a.next;
                    }
                }
                continue;
            }
            if (matchMacro(name)) |rep| {
                putS(dst, w, rep);
                continue;
            }
            // unknown \cmd{arg} (e.g. \text{}, \mathbb{}) -> unwrap the argument
            if (i < src.len and src[i] == '{' and depth < 8) {
                if (readBraced(src, i)) |a| {
                    writeMath(dst, w, a.inner, depth + 1);
                    i = a.next;
                    continue;
                }
            }
            // an unknown bare \cmd: emit it VERBATIM (with the backslash). This is the common case for ordinary
            // text — a Windows path (C:\Users), a regex (\d+), an escape (\t \n), a LaTeX section macro — which
            // must NOT lose its backslash. Only the KNOWN math macros above (\frac,\alpha,\times,...) transform.
            putB(dst, w, '\\');
            putS(dst, w, name);
            continue;
        }
        if (c == '^') {
            // superscript ONLY inside a math span ($...$ / \(...\)). Outside, a caret is literal so ordinary text
            // like "2^32" or "a^b" is never split/garbled (the exponent-corruption bug).
            if (in_math) {
                if (readScript(src, i + 1)) |sc| {
                    emitScript(dst, w, sc.arg, true);
                    i = sc.next;
                    continue;
                }
            }
            putB(dst, w, '^');
            i += 1;
            continue;
        }
        if (c == '_') {
            // subscript ONLY inside a math span AND when it clearly IS one (attached to an alnum, braced or a
            // single token at a word boundary). Outside math, '_' is snake_case/emphasis — emit it and let
            // cleanInline decide (so file_name / std_lib survive intact).
            const prev_al = i > 0 and isAlnum(src[i - 1]);
            if (in_math and prev_al and i + 1 < src.len) {
                if (src[i + 1] == '{') {
                    if (readScript(src, i + 1)) |sc| {
                        emitScript(dst, w, sc.arg, false);
                        i = sc.next;
                        continue;
                    }
                } else if (isAlnum(src[i + 1])) {
                    const after: u8 = if (i + 2 < src.len) src[i + 2] else ' ';
                    if (!isAlnum(after)) {
                        emitScript(dst, w, src[i + 1 .. i + 2], false);
                        i += 2;
                        continue;
                    }
                }
            }
            putB(dst, w, '_');
            i += 1;
            continue;
        }
        putB(dst, w, c);
        i += 1;
    }
}

/// Transform LaTeX-ish math in `src` to readable unicode/ASCII into `dst`. Returns bytes written (<= dst.len).
pub fn mathToUnicode(dst: []u8, src: []const u8) usize {
    var w: usize = 0;
    writeMath(dst, &w, src, 0);
    return w;
}

/// Does this line plausibly contain math worth transforming? (Cheap pre-check so pure prose skips the pass.)
pub fn hasMath(s: []const u8) bool {
    for (s) |c| {
        if (c == '$' or c == '\\' or c == '^') return true;
    }
    return false;
}

/// Copy `src` into `dst` with inline markdown resolved to readable text:
///   [text](url) / ![alt](url) → text          (the raw url is dropped)
///   **bold** / __bold__ / *em* / _em_ / `code` → the inner text (markers stripped)
///   <br> → a space
/// Emphasis markers are stripped only when WORD-ADJACENT, so `a * b` (literal) and `file_name`
/// (snake_case) survive intact — the old version stripped every '*' and no '_', which mangled math and
/// left `_italic_`/`__bold__`/`[links](...)` showing raw (the "markdown fails" reports). Returns bytes written.
pub fn cleanInline(dst: []u8, src: []const u8) usize {
    const trimmed = std.mem.trim(u8, src, " \t\r");
    // math pass FIRST (strips $, resolves \frac/\greek/operators/^/_ ) so the emphasis loop below runs on already
    // de-math'd text and never sees a bare backslash-command. Bounded to a stack scratch; a huge line (rare — a
    // whole paragraph on one line) skips math and renders as before rather than risk truncation.
    var mbuf: [4096]u8 = undefined;
    const s = if (trimmed.len <= 3500 and hasMath(trimmed)) mbuf[0..mathToUnicode(&mbuf, trimmed)] else trimmed;
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

test "mathToUnicode: delimiters, greek, operators, frac, scripts, currency" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("E=mc\u{00B2}", b[0..mathToUnicode(&b, "$E=mc^2$")]);
    try std.testing.expectEqualStrings("(a)/(b)", b[0..mathToUnicode(&b, "\\frac{a}{b}")]);
    try std.testing.expectEqualStrings("\u{03B1}+\u{03B2}", b[0..mathToUnicode(&b, "\\alpha+\\beta")]);
    try std.testing.expectEqualStrings("\u{2264} \u{2265} \u{00D7}", b[0..mathToUnicode(&b, "\\leq \\geq \\times")]);
    try std.testing.expectEqualStrings("\u{221A}(2)", b[0..mathToUnicode(&b, "\\sqrt{2}")]);
    try std.testing.expectEqualStrings("\u{2211}", b[0..mathToUnicode(&b, "\\sum")]);
    // currency ($ + digit) stays literal; unknown styling command unwraps its argument
    try std.testing.expectEqualStrings("it costs $5 today", b[0..mathToUnicode(&b, "it costs $5 today")]);
    try std.testing.expectEqualStrings("R", b[0..mathToUnicode(&b, "\\mathbb{R}")]);
    // \left \right and \[ \] delimiters drop cleanly
    try std.testing.expectEqualStrings("(x+1)", b[0..mathToUnicode(&b, "\\left(x+1\\right)")]);
    // REGRESSIONS: ordinary text must survive — backslash-bearing prose keeps its backslashes (Windows paths,
    // regex, escapes), and a bare caret/underscore outside a math span is literal (no exponent splitting).
    try std.testing.expectEqualStrings("open C:\\Users\\gary\\a.txt", b[0..mathToUnicode(&b, "open C:\\Users\\gary\\a.txt")]);
    try std.testing.expectEqualStrings("regex \\d+ then \\t tab", b[0..mathToUnicode(&b, "regex \\d+ then \\t tab")]);
    try std.testing.expectEqualStrings("2^32 bits and x_i idx", b[0..mathToUnicode(&b, "2^32 bits and x_i idx")]);
    // but inside a math span the scripts DO convert
    try std.testing.expectEqualStrings("2\u{00B3}\u{00B2}", b[0..mathToUnicode(&b, "$2^{32}$")]);
    try std.testing.expectEqualStrings("x\u{00B2}", b[0..mathToUnicode(&b, "\\(x^2\\)")]);
}

test "cleanInline runs math then emphasis, keeps snake_case" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("E=mc\u{00B2}", b[0..cleanInline(&b, "$E=mc^2$")]);
    // snake_case with no math trigger is untouched (hasMath false -> math pass skipped)
    try std.testing.expectEqualStrings("open file_name.txt", b[0..cleanInline(&b, "open file_name.txt")]);
    // a subscript index inside a math span
    try std.testing.expectEqualStrings("x\u{1D62}", b[0..cleanInline(&b, "$x_i$")]);
    // math + real emphasis on the same line
    try std.testing.expectEqualStrings("area = \u{03C0} r\u{00B2}", b[0..cleanInline(&b, "**area** = $\\pi r^2$")]);
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
