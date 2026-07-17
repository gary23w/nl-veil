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
// unicode (carried by the font atlas + theme.foldAscii), turn \frac{a}{b} into (a)/(b), and convert ^/_
// scripts to unicode super/subscripts. Everything unmappable degrades to readable ASCII — never a raw
// backslash-command and never a corrupted word. All output is bounded to dst.len.

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
            // like "2^32" or "a^b" is never split/garbled.
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
/// (snake_case) survive intact. Returns bytes written.
pub fn cleanInline(dst: []u8, src: []const u8) usize {
    const trimmed = std.mem.trim(u8, src, " \t\r");
    // math pass FIRST (strips $, resolves \frac/\greek/operators/^/_ ) so the emphasis loop below runs on
    // already de-math'd text and never sees a bare backslash-command. Bounded to a stack scratch; a huge
    // line (rare — a whole paragraph on one line) skips math rather than risk truncation.
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

// ---- styled inline spans — the chat renderer's REAL typography path -------------------------------------
// cleanInline above STRIPS markers to plain text (still used for mono table cells); parseInline below is the
// full replacement for the reading surface: it resolves the same inline grammar but KEEPS the structure as
// styled spans (bold/italic/inline-code/strikethrough/links with their urls), so the renderer can draw real
// weights, faces, code chips, and clickable links. Same robustness contract as everything in this file:
// bounded buffers, no allocation, hostile input degrades to readable literals — never a crash.

pub const Style = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,
    _pad: u3 = 0,

    pub fn eqlS(a: Style, b: Style) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

pub const NO_URL: u8 = 255;
pub const Span = struct { off: u16 = 0, len: u16 = 0, style: Style = .{}, url: u8 = NO_URL };
pub const MAX_SPANS = 48;
pub const MAX_URLS = 6;

/// One parsed line: display bytes + style runs over them. Stack-friendly (~6KB); reused per line.
pub const Inline = struct {
    text: [2048]u8 = undefined, // display bytes: math resolved, markers stripped, <br> → '\n' (hard break)
    text_len: usize = 0,
    spans: [MAX_SPANS]Span = undefined,
    span_count: usize = 0,
    urls: [MAX_URLS][512]u8 = undefined,
    url_lens: [MAX_URLS]usize = [_]usize{0} ** MAX_URLS,
    url_count: usize = 0,

    pub fn textOf(il: *const Inline, sp: Span) []const u8 {
        return il.text[sp.off .. sp.off + sp.len];
    }
    pub fn urlOf(il: *const Inline, sp: Span) ?[]const u8 {
        if (sp.url == NO_URL or sp.url >= il.url_count) return null;
        return il.urls[sp.url][0..il.url_lens[sp.url]];
    }
};

/// The next run of `fence` consecutive backticks at/after `from`, or null.
fn findFenceRun(s: []const u8, from: usize, fence: usize) ?usize {
    var i = from;
    while (i + fence <= s.len) : (i += 1) {
        if (s[i] != '`') continue;
        if (fence == 2 and s[i + 1] != '`') continue;
        return i;
    }
    return null;
}

/// Is there a viable CLOSING marker (`m` × count, outside code, with a non-space char before it) ahead of
/// `from`? Openers only activate when their pair exists — an unmatched `**` stays a literal, instead of
/// silently restyling the rest of the line.
fn findPair(w: []const u8, mask: []const bool, from: usize, m: u8, count: usize) bool {
    var i = from;
    while (i + count <= w.len) : (i += 1) {
        if (mask[i]) continue;
        if (w[i] != m) continue;
        if (count == 2 and (w[i + 1] != m or mask[i + 1])) continue;
        const prv: u8 = if (i > 0) w[i - 1] else ' ';
        if (prv == ' ' or prv == m) continue;
        return true;
    }
    return false;
}

const LinkParts = struct { label_end: usize, next: usize, url_from: usize, url_to: usize };

/// A well-formed "[label](url)" at `open` (open points at '['): the label-end index, the index past ')',
/// and the url range. null → the '[' is a literal.
fn parseLinkAt(w: []const u8, open: usize) ?LinkParts {
    var rb = open + 1;
    while (rb < w.len and w[rb] != ']') : (rb += 1) {
        if (w[rb] == '[') return null; // nested '[' — treat the whole thing as literal text
    }
    if (rb >= w.len or rb == open + 1) return null; // no ']' / empty label
    if (rb + 1 >= w.len or w[rb + 1] != '(') return null;
    var rp = rb + 2;
    while (rp < w.len and w[rp] != ')') : (rp += 1) {}
    if (rp >= w.len) return null;
    return .{ .label_end = rb, .next = rp + 1, .url_from = rb + 2, .url_to = rp };
}

fn storeUrl(out: *Inline, url_raw: []const u8) ?u8 {
    if (out.url_count >= MAX_URLS) return null;
    var u = std.mem.trim(u8, url_raw, " ");
    if (std.mem.indexOfScalar(u8, u, ' ')) |sp| u = u[0..sp]; // drop a `"title"` tail
    if (u.len == 0) return null;
    const idx: u8 = @intCast(out.url_count);
    const n = @min(u.len, out.urls[idx].len);
    @memcpy(out.urls[idx][0..n], u[0..n]);
    out.url_lens[idx] = n;
    out.url_count += 1;
    return idx;
}

const Emitter = struct {
    out: *Inline,
    cur: Style = .{},
    cur_url: u8 = NO_URL,
    span_start: usize = 0,

    fn flush(e: *Emitter) void {
        const len = e.out.text_len - e.span_start;
        if (len == 0) return;
        if (e.out.span_count < MAX_SPANS) {
            e.out.spans[e.out.span_count] = .{
                .off = @intCast(e.span_start),
                .len = @intCast(len),
                .style = e.cur,
                .url = e.cur_url,
            };
            e.out.span_count += 1;
        } else {
            // span table full — grow the LAST span instead (style detail degrades, text never drops)
            const last = &e.out.spans[MAX_SPANS - 1];
            last.len = @intCast(e.out.text_len - last.off);
        }
        e.span_start = e.out.text_len;
    }

    fn put(e: *Emitter, b: u8, want: Style, url: u8) void {
        if (!e.cur.eqlS(want) or e.cur_url != url) {
            e.flush();
            e.cur = want;
            e.cur_url = url;
        }
        if (e.out.text_len < e.out.text.len) {
            e.out.text[e.out.text_len] = b;
            e.out.text_len += 1;
        }
    }
};

/// Parse one source line into display text + styled spans. Grammar (pragmatic GFM subset, matching what
/// models actually emit): `code`/``code`` (verbatim — no math, no emphasis inside), **bold** __bold__,
/// *italic* _italic_ (word-flanked; snake_case and `a * b` survive), ~~strike~~, [label](url), ![alt](url),
/// bare http(s):// autolinks, <br> → hard break, LaTeX-ish math via mathToUnicode outside code. Unpaired
/// markers stay literal. Always produces at least one span when any text survives.
pub fn parseInline(out: *Inline, src: []const u8) void {
    out.text_len = 0;
    out.span_count = 0;
    out.url_count = 0;
    const trimmed = std.mem.trim(u8, src, " \t\r");

    // ---- phase A: lift out `code` spans (verbatim), math-convert everything else, into work[] + mask ----
    var work: [2048]u8 = undefined;
    var mask: [2048]bool = undefined; // true = this byte belongs to an inline-code span
    var wn: usize = 0;
    {
        var i: usize = 0;
        while (i < trimmed.len and wn < work.len) {
            if (trimmed[i] == '`') {
                const fence: usize = if (i + 1 < trimmed.len and trimmed[i + 1] == '`') 2 else 1;
                const open_end = i + fence;
                if (findFenceRun(trimmed, open_end, fence)) |close| {
                    var body = trimmed[open_end..close];
                    if (fence == 2 and body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ')
                        body = body[1 .. body.len - 1]; // `` ` `` convention: symmetric pad space trims
                    for (body) |bc| {
                        if (wn >= work.len) break;
                        work[wn] = if (bc == '\n' or bc == '\t') ' ' else bc;
                        mask[wn] = true;
                        wn += 1;
                    }
                    i = close + fence;
                    continue;
                }
                var k: usize = 0; // no closer — literal backtick(s)
                while (k < fence and wn < work.len) : (k += 1) {
                    work[wn] = '`';
                    mask[wn] = false;
                    wn += 1;
                }
                i = open_end;
                continue;
            }
            var j = i;
            while (j < trimmed.len and trimmed[j] != '`') j += 1;
            const chunk = trimmed[i..j];
            var mbuf: [4096]u8 = undefined;
            const mathed = if (chunk.len <= 3500 and hasMath(chunk)) mbuf[0..mathToUnicode(&mbuf, chunk)] else chunk;
            for (mathed) |mc| {
                if (wn >= work.len) break;
                work[wn] = mc;
                mask[wn] = false;
                wn += 1;
            }
            i = j;
        }
    }

    // ---- phase B: emphasis/link scan over work[], emitting bytes + style runs ----
    var e = Emitter{ .out = out };
    var st = Style{};
    var link_end: usize = std.math.maxInt(usize); // work-index where the open link's label ends
    var link_resume: usize = std.math.maxInt(usize); // work-index to continue from after the label (skips "(url)")
    var i: usize = 0;
    while (i < wn) {
        // an open [label](...) ends here — drop the link style and jump past its "(url)" tail
        if (st.link and i == link_end) {
            st.link = false;
            i = link_resume;
            continue;
        }
        const c = work[i];
        if (mask[i]) {
            var want = st;
            want.code = true; // code renders mono regardless; surrounding emphasis rides along
            e.put(c, want, if (st.link) e.cur_url else NO_URL);
            i += 1;
            continue;
        }
        {
            // <br> family → hard break
            if (c == '<' and (mdstarts(work[i..wn], "<br>") or mdstarts(work[i..wn], "<br/>") or mdstarts(work[i..wn], "<br />"))) {
                while (e.out.text_len > 0 and e.out.text[e.out.text_len - 1] == ' ') e.out.text_len -= 1; // no trailing pad on the broken line
                e.put('\n', st, NO_URL);
                const gt = std.mem.indexOfScalarPos(u8, work[0..wn], i, '>') orelse wn - 1;
                i = gt + 1;
                continue;
            }
            // doubled markers: **bold** __bold__ ~~strike~~
            if ((c == '*' or c == '_' or c == '~') and i + 1 < wn and work[i + 1] == c and !mask[i + 1]) {
                const strike = c == '~';
                const active = if (strike) st.strike else st.bold;
                if (!active) {
                    const nxt: u8 = if (i + 2 < wn) work[i + 2] else ' ';
                    if (nxt != ' ' and findPair(work[0..wn], mask[0..wn], i + 2, c, 2)) {
                        if (strike) st.strike = true else st.bold = true;
                        i += 2;
                        continue;
                    }
                } else {
                    const prv: u8 = if (e.out.text_len > 0) e.out.text[e.out.text_len - 1] else ' ';
                    if (prv != ' ') {
                        if (strike) st.strike = false else st.bold = false;
                        i += 2;
                        continue;
                    }
                }
                if (c == '~') { // a literal ~~ (no pair): fall through as ordinary bytes
                    e.put(c, st, if (st.link) e.cur_url else NO_URL);
                    i += 1;
                    continue;
                }
                // literal * / _ pair — emit this one; the loop revisits the second
                e.put(c, st, if (st.link) e.cur_url else NO_URL);
                i += 1;
                continue;
            }
            // single * / _ → italic (word-flanked; snake_case '_' survives)
            if (c == '*' or c == '_') {
                const prv: u8 = if (e.out.text_len > 0) e.out.text[e.out.text_len - 1] else ' ';
                const nxt: u8 = if (i + 1 < wn) work[i + 1] else ' ';
                if (!st.italic) {
                    const snake = c == '_' and isAlnum(prv);
                    if (!snake and nxt != ' ' and nxt != c and findPair(work[0..wn], mask[0..wn], i + 1, c, 1)) {
                        st.italic = true;
                        i += 1;
                        continue;
                    }
                } else {
                    const snake = c == '_' and isAlnum(nxt);
                    if (!snake and prv != ' ') {
                        st.italic = false;
                        i += 1;
                        continue;
                    }
                }
                e.put(c, st, if (st.link) e.cur_url else NO_URL);
                i += 1;
                continue;
            }
            // [label](url) / ![alt](url)
            if (!st.link and (c == '[' or (c == '!' and i + 1 < wn and work[i + 1] == '[' and !mask[i + 1]))) {
                const open = if (c == '!') i + 1 else i;
                if (parseLinkAt(work[0..wn], open)) |lk| {
                    if (storeUrl(out, work[lk.url_from..lk.url_to])) |uidx| {
                        st.link = true;
                        e.flush();
                        e.cur_url = uidx; // the label's spans carry this url
                        link_end = lk.label_end;
                        link_resume = lk.next;
                        i = open + 1;
                        continue;
                    }
                }
                // malformed / url table full — the bracket is literal
            }
            // bare autolink
            if (!st.link and c == 'h' and (mdstarts(work[i..wn], "http://") or mdstarts(work[i..wn], "https://"))) {
                var end = i;
                while (end < wn and work[end] != ' ' and work[end] != '\n' and !mask[end]) end += 1;
                var trimmed_end = end;
                while (trimmed_end > i and (work[trimmed_end - 1] == '.' or work[trimmed_end - 1] == ',' or
                    work[trimmed_end - 1] == ';' or work[trimmed_end - 1] == ':' or work[trimmed_end - 1] == '!' or
                    work[trimmed_end - 1] == '?' or work[trimmed_end - 1] == ')' or work[trimmed_end - 1] == '"' or
                    work[trimmed_end - 1] == '\'')) trimmed_end -= 1;
                if (trimmed_end > i + 8) {
                    if (storeUrl(out, work[i..trimmed_end])) |uidx| {
                        var want = st;
                        want.link = true;
                        var k = i; // emit the whole url in one styled run — its _ and * are literal url bytes
                        while (k < trimmed_end) : (k += 1) e.put(work[k], want, uidx);
                        i = trimmed_end;
                        continue;
                    }
                }
            }
        }
        // ordinary byte (collapse runs of spaces outside code)
        if (c == ' ' and e.out.text_len > 0 and e.out.text[e.out.text_len - 1] == ' ') {
            i += 1;
            continue;
        }
        e.put(c, st, if (st.link) e.cur_url else NO_URL);
        i += 1;
    }
    while (out.text_len > 0 and out.text[out.text_len - 1] == ' ') out.text_len -= 1; // trailing pad
    e.flush();
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

// ---- parseInline (styled spans) ----

fn spanText(il: *const Inline, idx: usize) []const u8 {
    return il.textOf(il.spans[idx]);
}

test "parseInline: bold/italic/code split into styled runs; plain text stays one span" {
    var il: Inline = .{};
    parseInline(&il, "**bold** and *em* and `code`");
    try std.testing.expectEqualStrings("bold and em and code", il.text[0..il.text_len]);
    try std.testing.expectEqual(@as(usize, 5), il.span_count);
    try std.testing.expectEqualStrings("bold", spanText(&il, 0));
    try std.testing.expect(il.spans[0].style.bold and !il.spans[0].style.italic);
    try std.testing.expectEqualStrings(" and ", spanText(&il, 1));
    try std.testing.expect(!il.spans[1].style.bold);
    try std.testing.expectEqualStrings("em", spanText(&il, 2));
    try std.testing.expect(il.spans[2].style.italic);
    try std.testing.expectEqualStrings("code", spanText(&il, 4));
    try std.testing.expect(il.spans[4].style.code);

    parseInline(&il, "just plain prose");
    try std.testing.expectEqual(@as(usize, 1), il.span_count);
    try std.testing.expectEqualStrings("just plain prose", spanText(&il, 0));
    try std.testing.expect(!il.spans[0].style.bold and !il.spans[0].style.code);
}

test "parseInline: literals survive — snake_case, lone *, unpaired markers, stray backtick" {
    var il: Inline = .{};
    parseInline(&il, "open file_name.txt in std_lib");
    try std.testing.expectEqualStrings("open file_name.txt in std_lib", il.text[0..il.text_len]);
    try std.testing.expectEqual(@as(usize, 1), il.span_count);
    parseInline(&il, "Multiply a * b now");
    try std.testing.expectEqualStrings("Multiply a * b now", il.text[0..il.text_len]);
    parseInline(&il, "**unclosed bold");
    try std.testing.expectEqualStrings("**unclosed bold", il.text[0..il.text_len]);
    parseInline(&il, "a ` stray tick");
    try std.testing.expectEqualStrings("a ` stray tick", il.text[0..il.text_len]);
    parseInline(&il, "~~kept");
    try std.testing.expectEqualStrings("~~kept", il.text[0..il.text_len]);
}

test "parseInline: strikethrough, bold across inline code, underscores inside code stay literal" {
    var il: Inline = .{};
    parseInline(&il, "~~gone~~ stays");
    try std.testing.expectEqualStrings("gone stays", il.text[0..il.text_len]);
    try std.testing.expect(il.spans[0].style.strike);
    try std.testing.expect(!il.spans[1].style.strike);
    // emphasis rides across a code span; the code keeps its own flag too
    parseInline(&il, "**bold `code` tail**");
    try std.testing.expectEqualStrings("bold code tail", il.text[0..il.text_len]);
    try std.testing.expect(il.spans[0].style.bold and !il.spans[0].style.code);
    try std.testing.expect(il.spans[1].style.bold and il.spans[1].style.code);
    try std.testing.expect(il.spans[2].style.bold and !il.spans[2].style.code);
    // markers inside code are verbatim bytes
    parseInline(&il, "run `a_b * c_d` now");
    try std.testing.expectEqualStrings("run a_b * c_d now", il.text[0..il.text_len]);
}

test "parseInline: links carry their url; images show alt; autolinks are clickable; label emphasis strips" {
    var il: Inline = .{};
    parseInline(&il, "see [the docs](https://ziglang.org/doc) for more");
    try std.testing.expectEqualStrings("see the docs for more", il.text[0..il.text_len]);
    try std.testing.expectEqual(@as(usize, 3), il.span_count);
    try std.testing.expect(il.spans[1].style.link);
    try std.testing.expectEqualStrings("the docs", spanText(&il, 1));
    try std.testing.expectEqualStrings("https://ziglang.org/doc", il.urlOf(il.spans[1]).?);
    try std.testing.expect(il.urlOf(il.spans[0]) == null);

    parseInline(&il, "![logo](x.png) shown");
    try std.testing.expectEqualStrings("logo shown", il.text[0..il.text_len]);
    try std.testing.expectEqualStrings("x.png", il.urlOf(il.spans[0]).?);

    parseInline(&il, "go to https://ziglang.org/download now.");
    try std.testing.expectEqualStrings("go to https://ziglang.org/download now.", il.text[0..il.text_len]);
    try std.testing.expect(il.spans[1].style.link);
    try std.testing.expectEqualStrings("https://ziglang.org/download", il.urlOf(il.spans[1]).?);

    // a url with underscores must not trigger italics
    parseInline(&il, "https://x.y/a_b_c end");
    try std.testing.expectEqualStrings("https://x.y/a_b_c end", il.text[0..il.text_len]);

    // link title tails drop; a bold label strips its markers but keeps the url
    parseInline(&il, "[**bold label**](https://x.y \"title\")");
    try std.testing.expectEqualStrings("bold label", il.text[0..il.text_len]);
    try std.testing.expect(il.spans[0].style.link and il.spans[0].style.bold);
    try std.testing.expectEqualStrings("https://x.y", il.urlOf(il.spans[0]).?);

    // malformed stays literal
    parseInline(&il, "[unclosed bracket");
    try std.testing.expectEqualStrings("[unclosed bracket", il.text[0..il.text_len]);
}

test "parseInline: math resolves outside code, never inside; <br> becomes a hard break" {
    var il: Inline = .{};
    parseInline(&il, "area = $\\pi r^2$");
    try std.testing.expectEqualStrings("area = \u{03C0} r\u{00B2}", il.text[0..il.text_len]);
    parseInline(&il, "`$x^2$` literal");
    try std.testing.expectEqualStrings("$x^2$ literal", il.text[0..il.text_len]);
    try std.testing.expect(il.spans[0].style.code);
    parseInline(&il, "line one<br>line two");
    try std.testing.expectEqualStrings("line one\nline two", il.text[0..il.text_len]);
}

test "parseInline: hostile input never crashes and always yields bounded output" {
    var il: Inline = .{};
    // marker storm
    parseInline(&il, "*** ** * `` ` ~~ __ _ [ ]( ![ <br");
    try std.testing.expect(il.text_len <= il.text.len);
    // a giant spaceless run (the renderWrapped OOB class of input)
    var big: [3000]u8 = undefined;
    @memset(&big, 'x');
    big[0] = '*';
    big[1] = '*';
    parseInline(&il, &big);
    try std.testing.expect(il.text_len <= il.text.len);
    try std.testing.expect(il.span_count >= 1);
    // many links overflow the url table gracefully (later links render as text)
    parseInline(&il, "[a](u1) [b](u2) [c](u3) [d](u4) [e](u5) [f](u6) [g](u7) [h](u8)");
    try std.testing.expect(il.url_count <= MAX_URLS);
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
