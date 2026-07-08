//! theme.zig — the nl-veil visual language for the desktop shell.
//! Palette is the exact Tokyo Night set from web/public/styles.css so veil-desk and the web UI read as
//! one product. Everything here is immediate-mode: no retained widget tree, just draw + hit-test helpers
//! called each frame against the raylib backend, so the whole UI is a pure function of AppState.

const std = @import("std");
const rl = @import("raylib");
const log = @import("log.zig");

pub const Color = rl.Color;
pub const Rect = rl.Rectangle;
pub const Vec2 = rl.Vector2;

fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

fn hexByte(hi: u8, lo: u8) u8 {
    return (hexNibble(hi) << 4) | hexNibble(lo);
}

fn hex(comptime s: []const u8) Color {
    return .{ .r = hexByte(s[0], s[1]), .g = hexByte(s[2], s[3]), .b = hexByte(s[4], s[5]), .a = 255 };
}

pub const Scheme = enum(u8) { dark = 0, light = 1 };

const Palette = struct {
    bg: Color,
    bg_dark: Color,
    bg_hl: Color,
    bg_sel: Color,
    fg: Color,
    fg_dim: Color,
    comment: Color,
    border: Color,
    blue: Color,
    cyan: Color,
    green: Color,
    magenta: Color,
    orange: Color,
    red: Color,
    yellow: Color,
    teal: Color,
};

// Default dark palette (Tokyo Night, mirrors web/public/styles.css).
// fg is a soft off-white rather than pure #fff — full-blast white on a dark ground reads harsh; the
// slightly blued white keeps the same contrast band as the web UI without the glare.
const dark_palette = Palette{
    .bg = hex("1a1b26"),
    .bg_dark = hex("16161e"),
    .bg_hl = hex("1f2335"),
    .bg_sel = hex("283457"),
    .fg = hex("e9edfa"),
    .fg_dim = hex("a9b1d6"),
    .comment = hex("565f89"),
    .border = hex("292e42"),
    .blue = hex("7aa2f7"),
    .cyan = hex("7dcfff"),
    .green = hex("9ece6a"),
    .magenta = hex("bb9af7"),
    .orange = hex("ff9e64"),
    .red = hex("f7768e"),
    .yellow = hex("e0af68"),
    .teal = hex("2ac3de"),
};

// Light palette tuned for readable contrast in the same visual language. fg is near-black (not #000 —
// pure black on a pale ground is the same glare problem in reverse) and the border sits closer to the
// panel fills so the chrome reads as soft edges, not wireframe.
const light_palette = Palette{
    .bg = hex("f5f7fb"),
    .bg_dark = hex("e9edf5"),
    .bg_hl = hex("dfe7f4"),
    .bg_sel = hex("cfdcf3"),
    .fg = hex("14182b"),
    .fg_dim = hex("46557a"),
    .comment = hex("6d7a99"),
    .border = hex("d3dbe9"),
    .blue = hex("2f6feb"),
    .cyan = hex("0b84a5"),
    .green = hex("2f8f46"),
    .magenta = hex("8a3ffc"),
    .orange = hex("c27a00"),
    .red = hex("c93a4a"),
    .yellow = hex("a06a00"),
    .teal = hex("0f8a83"),
};

var scheme: Scheme = .light;

pub var bg: Color = light_palette.bg;
pub var bg_dark: Color = light_palette.bg_dark;
pub var bg_hl: Color = light_palette.bg_hl;
pub var bg_sel: Color = light_palette.bg_sel;
pub var fg: Color = light_palette.fg;
pub var fg_dim: Color = light_palette.fg_dim;
pub var comment: Color = light_palette.comment;
pub var border: Color = light_palette.border;
pub var blue: Color = light_palette.blue;
pub var cyan: Color = light_palette.cyan;
pub var green: Color = light_palette.green;
pub var magenta: Color = light_palette.magenta;
pub var orange: Color = light_palette.orange;
pub var red: Color = light_palette.red;
pub var yellow: Color = light_palette.yellow;
pub var teal: Color = light_palette.teal;

fn applyPalette(p: Palette) void {
    bg = p.bg;
    bg_dark = p.bg_dark;
    bg_hl = p.bg_hl;
    bg_sel = p.bg_sel;
    fg = p.fg;
    fg_dim = p.fg_dim;
    comment = p.comment;
    border = p.border;
    blue = p.blue;
    cyan = p.cyan;
    green = p.green;
    magenta = p.magenta;
    orange = p.orange;
    red = p.red;
    yellow = p.yellow;
    teal = p.teal;
}

pub fn setScheme(s: Scheme) void {
    if (scheme == s) return;
    log.trace("theme.setScheme {t} -> {t}", .{ scheme, s });
    scheme = s;
    applyPalette(if (s == .light) light_palette else dark_palette);
}

pub fn setSchemeFromInt(v: u8) void {
    setScheme(if (v == 1) .light else .dark);
}

pub fn getScheme() Scheme {
    return scheme;
}

pub fn schemeInt() u8 {
    return @intFromEnum(scheme);
}

pub fn withAlpha(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// Linear mix of two colors (k=0 → a, k=1 → b). Buttons use it for hover/press shades so every accent
/// gets consistent state feedback without hand-picking per-color variants.
fn blend(a: Color, b: Color, k: f32) Color {
    const ik = 1.0 - k;
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * ik + @as(f32, @floatFromInt(b.r)) * k),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * ik + @as(f32, @floatFromInt(b.g)) * k),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * ik + @as(f32, @floatFromInt(b.b)) * k),
        .a = 255,
    };
}

fn luma(c: Color) f32 {
    return 0.299 * @as(f32, @floatFromInt(c.r)) + 0.587 * @as(f32, @floatFromInt(c.g)) + 0.114 * @as(f32, @floatFromInt(c.b));
}

// ---- design tokens: ONE spacing/sizing scale for the whole shell ----
// Every tab draws against these instead of sprinkling magic paddings, so the rhythm is uniform:
// PAD around a page, PAD_IN inside a panel, GAP between siblings, and three button heights.
pub const PAD: f32 = 16; // outer page padding
pub const PAD_IN: f32 = 12; // padding inside a panel
pub const GAP: f32 = 12; // gap between sibling widgets/cards
pub const BTN_SM: f32 = 24; // inline chip-sized button
pub const BTN_MD: f32 = 34; // standard form button (matches FIELD_H so paired rows align)
pub const BTN_LG: f32 = 40; // page-level call to action
pub const FIELD_H: f32 = 34; // single-line text input height

// ---- mouse cursor feedback: widgets *request* a cursor while hovered; the frame applies ONE winner ----
// Later draws win (overlays are drawn last, so their request naturally overrides covered widgets).
// applyCursor() is called once per frame by main; it only touches the OS cursor on a change.
var cursor_want: rl.MouseCursor = .default;
var cursor_now: rl.MouseCursor = .default;
pub fn wantCursor(c: rl.MouseCursor) void {
    cursor_want = c;
}
pub fn applyCursor() void {
    if (cursor_want != cursor_now) {
        rl.setMouseCursor(cursor_want);
        cursor_now = cursor_want;
    }
    cursor_want = .default;
}

/// raylib's rounded-rect "roundness" is RELATIVE to the rect's short side, so the same 0.14 gave a big
/// button soft corners and a small chip nearly-square ones. Convert a PIXEL radius to the ratio so every
/// widget shares one corner language.
fn roundnessFor(r: Rect, radius_px: f32) f32 {
    const m = @min(r.width, r.height);
    if (m <= 1) return 0;
    return @min(1.0, (radius_px * 2.0) / m);
}

// ---- text: a RING of scratch buffers + a loaded TTF ----
//
// The UI is single-threaded, but a SINGLE static buffer is a trap: Zig evaluates call arguments left to
// right, so `text(z("desk"), x + measure(z("veil")), ...)` computes the position AFTER z() has already
// overwritten the buffer the first arg points at — the logo rendered "veil veil", and an array of four
// z()'d tab labels all pointed at the last one ("Settings"). A ring of buffers lets many z() results stay
// live at once, which is exactly what nested/argument-order use needs.
const ZBUFS = 24;
var zbufs: [ZBUFS][2048]u8 = undefined;
var zi: usize = 0;
fn nextBuf() *[2048]u8 {
    zi = (zi + 1) % ZBUFS;
    return &zbufs[zi];
}
pub fn z(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const b = nextBuf();
    return std.fmt.bufPrintZ(b, fmt, args) catch {
        b[0] = 0;
        return b[0..0 :0];
    };
}
pub fn zs(s: []const u8) [:0]const u8 {
    const b = nextBuf();
    const n = foldAscii(b[0 .. b.len - 1], s);
    b[n] = 0;
    return b[0..n :0];
}

/// Copy `src` into `dst`, folding it to renderable single-line ASCII. TWO jobs, both fixing real bugs seen
/// in LLM-authored text (swarm goals/briefs, console events, chat):
///   1) newlines/tabs/other control bytes -> a single space, so a multi-line string never renders as
///      several OVERLAPPING lines (drawTextEx honours '\n'); one-line row labels stay one line.
///   2) common Unicode punctuation the UI/mono fonts don't carry (em/en dashes, smart quotes, bullets,
///      ellipsis, arrows, non-breaking space) -> its ASCII equivalent, so it never renders as tofu '?'.
/// Printable Latin-1 (accents) is kept verbatim — the atlas covers 0xA0..0xFF. Anything else (emoji, CJK,
/// rare symbols) is dropped rather than shown as '?'. Returns bytes written (never exceeds dst.len).
pub fn foldAscii(dst: []u8, src: []const u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < src.len and o < dst.len) {
        const b = src[i];
        if (b < 0x80) {
            dst[o] = if (b < 0x20 or b == 0x7F) ' ' else b; // controls (incl. \n \r \t) -> space
            o += 1;
            i += 1;
            continue;
        }
        const seq = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1; // invalid lead byte — skip it
            continue;
        };
        if (i + seq > src.len) break;
        const cp = std.unicode.utf8Decode(src[i .. i + seq]) catch {
            i += 1;
            continue;
        };
        const orig = src[i .. i + seq];
        i += seq;
        const rep: []const u8 = switch (cp) {
            0xA0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => " ",
            0x200B...0x200D, 0xFEFF => "", // zero-width — drop
            0xAD, 0x2010...0x2015, 0x2043, 0x2212 => "-",
            0x2018, 0x2019, 0x201A, 0x201B, 0x2032 => "'",
            0x201C, 0x201D, 0x201E, 0x201F, 0x2033 => "\"",
            0x2023, 0x2027, 0x25AA => "*", // bullets the atlas lacks -> '*'
            0x2026 => "...",
            0x21D0 => "<-", // <= not in the atlas
            0x2713, 0x2714 => "v",
            0x00A1...0x00AC, 0x00AE...0x00FF => orig, // printable Latin-1 — atlas has it, keep verbatim
            // Greek + super/subscript blocks — now in the font atlas, so pass through for real math rendering.
            0x0391...0x03C9, 0x2070...0x209C => orig,
            // Math operators/relations, real bullets/circles/arrows, and the scattered subscript letters (i j r u v)
            // — all added to the atlas (see main.glyph_set), so keep them verbatim instead of dropping/ASCII-folding.
            0x2022, 0x25CB, 0x25CF, 0x25E6, 0x2044, 0x2190...0x2193, 0x21D2, 0x2202, 0x2207, 0x2208, 0x2209, 0x220F, 0x2211, 0x221A, 0x221D, 0x221E, 0x2229, 0x222A, 0x222B, 0x2248, 0x2260, 0x2261, 0x2264, 0x2265, 0x22C5, 0x1D62...0x1D65, 0x2C7C => orig,
            else => "", // emoji / CJK / rare symbol — drop, never tofu
        };
        for (rep) |rb| {
            if (o >= dst.len) break;
            dst[o] = rb;
            o += 1;
        }
    }
    return o;
}

// The loaded fonts (real TTFs, loaded at startup). `ui_font` is proportional (labels, buttons, headers);
// `mono_font` is fixed-width for the log console so its columns line up. Until set, fall back to raylib's
// default. Drawing goes through drawTextEx for kerning + antialiasing.
var ui_font: ?rl.Font = null;
var mono_font: ?rl.Font = null;
var mark_tex: ?rl.Texture = null;
var mark_tex_attempted: bool = false;

fn scrubTransparentRgb(img: *rl.Image) void {
    if (img.width <= 0 or img.height <= 0) return;
    img.setFormat(.uncompressed_r8g8b8a8);
    const w: usize = @intCast(img.width);
    const h: usize = @intCast(img.height);
    const px_count: usize = w * h;
    const data: [*]u8 = @ptrCast(img.data);
    var i: usize = 0;
    while (i < px_count) : (i += 1) {
        const p = i * 4;
        if (data[p + 3] == 0) {
            data[p + 0] = 0;
            data[p + 1] = 0;
            data[p + 2] = 0;
        }
    }
}

pub fn setFont(f: rl.Font) void {
    log.trace("theme.setFont", .{});
    ui_font = f;
}
pub fn setMono(f: rl.Font) void {
    log.trace("theme.setMono", .{});
    mono_font = f;
}
pub fn deinit() void {
    log.trace("theme.deinit", .{});
    if (mark_tex) |tex| rl.unloadTexture(tex);
    mark_tex = null;
    mark_tex_attempted = false;
}

fn ensureMarkTexture() void {
    if (mark_tex_attempted) return;
    log.trace("theme.ensureMarkTexture loading", .{});
    mark_tex_attempted = true;
    const candidates = [_][:0]const u8{
        "assets/icon.png",
        "desktop/assets/icon.png",
        "../assets/icon.png",
        "../desktop/assets/icon.png",
    };
    for (candidates) |path| {
        if (rl.loadImage(path)) |loaded| {
            var img = loaded;
            defer rl.unloadImage(img);
            scrubTransparentRgb(&img);
            if (rl.loadTextureFromImage(img)) |tex| {
                rl.setTextureFilter(tex, .bilinear);
                mark_tex = tex;
                return;
            } else |_| {}
        } else |_| {}
    }
}
fn theFont() rl.Font {
    return ui_font orelse (rl.getFontDefault() catch unreachable);
}
fn theMono() rl.Font {
    return mono_font orelse theFont();
}
// A real TTF carries its own advances; extra tracking made the UI text look spaced-out/"broken". Keep it
// near zero for the proportional font (the mono path uses its own fixed 0.5 in textMono).
fn spacingFor(size: i32) f32 {
    return @max(0.0, @as(f32, @floatFromInt(size)) / 64.0);
}

pub fn text(s: [:0]const u8, x: i32, y: i32, size: i32, c: Color) void {
    rl.drawTextEx(theFont(), s, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, @floatFromInt(size), spacingFor(size), c);
}

pub fn measure(s: [:0]const u8, size: i32) i32 {
    return @intFromFloat(rl.measureTextEx(theFont(), s, @floatFromInt(size), spacingFor(size)).x);
}

/// Monospace draw (log console) — fixed advances so aligned columns actually align.
pub fn textMono(s: [:0]const u8, x: i32, y: i32, size: i32, c: Color) void {
    rl.drawTextEx(theMono(), s, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, @floatFromInt(size), 0.5, c);
}
pub fn measureMono(s: [:0]const u8, size: i32) i32 {
    return @intFromFloat(rl.measureTextEx(theMono(), s, @floatFromInt(size), 0.5).x);
}
/// Monospace clip helper for the console.
pub fn textMonoClip(s: []const u8, x: i32, y: i32, size: i32, c: Color, max_w: i32) void {
    const b = nextBuf();
    var n = foldAscii(b[0 .. b.len - 1], s);
    b[n] = 0;
    while (n > 1 and measureMono(b[0..n :0], size) > max_w) {
        n -= 1;
        b[n] = 0;
    }
    textMono(b[0..n :0], x, y, size, c);
}

/// Left-aligned label, clipped to max_w px with an ellipsis — the workhorse for rows that must not overflow.
pub fn textClip(s: []const u8, x: i32, y: i32, size: i32, c: Color, max_w: i32) void {
    const b = nextBuf();
    var n = foldAscii(b[0 .. b.len - 1], s);
    b[n] = 0;
    while (n > 1 and measure(b[0..n :0], size) > max_w) {
        n -= 1;
        b[n] = 0;
        if (n > 2) {
            b[n - 1] = '.';
            b[n - 2] = '.';
        }
    }
    text(b[0..n :0], x, y, size, c);
}

pub fn panel(r: Rect, fill: Color) void {
    rl.drawRectangleRounded(r, roundnessFor(r, 7), 8, fill);
}

pub fn panelBordered(r: Rect, fill: Color, line: Color) void {
    const rn = roundnessFor(r, 7);
    rl.drawRectangleRounded(r, rn, 8, fill);
    rl.drawRectangleRoundedLinesEx(r, rn, 8, 1.0, line);
}

pub fn fillRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    rl.drawRectangle(x, y, w, h, c);
}

pub fn hline(x: i32, y: i32, w: i32, c: Color) void {
    rl.drawRectangle(x, y, w, 1, c);
}

pub fn statusDot(x: i32, y: i32, c: Color) void {
    rl.drawCircle(x, y, 4.0, c);
}

const mouse = struct {
    fn pos() Vec2 {
        return rl.getMousePosition();
    }
    fn over(r: Rect) bool {
        return rl.checkCollisionPointRec(rl.getMousePosition(), r);
    }
    fn clicked(r: Rect) bool {
        return rl.checkCollisionPointRec(rl.getMousePosition(), r) and rl.isMouseButtonPressed(.left);
    }
};

pub fn hovering(r: Rect) bool {
    return mouse.over(r);
}

// When an overlay (an open dropdown list) is drawn on top of a form, clicks meant for the overlay would
// otherwise ALSO fire the widgets underneath (which were hit-tested earlier in the frame). While this is set,
// button()/checkbox() ignore clicks — the caller sets it true before drawing the covered widgets and false
// again before drawing the overlay itself, so only the overlay consumes the click.
var clicks_blocked: bool = false;
pub fn setBlockClicks(v: bool) void {
    clicks_blocked = v;
}

// ---- buttons: ONE widget, three visual weights ----
// solid = the page's primary action (filled accent, auto-contrast label)
// tonal = everything else (soft accent wash, accent label) — the default `button`
// ghost = quiet inline affordances (invisible until hovered)
// All three: height-scaled label size (no more 14px text jammed in a 20px chip), pixel-radius corners,
// press feedback (darker fill + 1px label nudge), and a pointing-hand cursor while hot.
pub const BtnStyle = enum { solid, tonal, ghost };

/// Label size that fits the button's height with sane breathing room.
pub fn btnFont(h: f32) i32 {
    if (h >= 38) return 15;
    if (h >= 30) return 14;
    if (h >= 24) return 13;
    if (h >= 20) return 12;
    return 11;
}

/// The width this label WANTS at height `h` — measure + symmetric padding. Call sites size buttons with
/// this instead of hardcoding widths, so a label can never overflow its own button.
pub fn btnW(label: [:0]const u8, h: f32) f32 {
    const hpad = @max(12.0, @min(20.0, h * 0.55));
    return @as(f32, @floatFromInt(measure(label, btnFont(h)))) + hpad * 2;
}

pub fn buttonEx(r: Rect, label: [:0]const u8, accent: Color, enabled: bool, style: BtnStyle) bool {
    const hot = enabled and mouse.over(r);
    const down = hot and rl.isMouseButtonDown(.left) and !clicks_blocked;
    const rad = @min(8.0, r.height * 0.32);
    const rn = roundnessFor(r, rad);
    var label_c = fg;
    if (!enabled) {
        if (style != .ghost) rl.drawRectangleRounded(r, rn, 8, withAlpha(bg_hl, 140));
        label_c = comment;
    } else switch (style) {
        .solid => {
            const fill = if (down) blend(accent, bg_dark, 0.25) else if (hot) blend(accent, fg, 0.12) else accent;
            rl.drawRectangleRounded(r, rn, 8, fill);
            // auto-contrast: dark-scheme accents are light pastels (dark label), light-scheme accents are
            // saturated darks (light label) — luma picks per accent, not per scheme.
            label_c = if (luma(accent) >= 150) Color{ .r = 0x14, .g = 0x16, .b = 0x20, .a = 255 } else Color{ .r = 0xfa, .g = 0xfb, .b = 0xff, .a = 255 };
        },
        .tonal => {
            const a: u8 = if (down) 92 else if (hot) 64 else 36;
            rl.drawRectangleRounded(r, rn, 8, withAlpha(accent, a));
            label_c = if (hot) blend(accent, fg, 0.30) else accent;
        },
        .ghost => {
            if (down) {
                rl.drawRectangleRounded(r, rn, 8, bg_sel);
            } else if (hot) {
                rl.drawRectangleRounded(r, rn, 8, bg_hl);
            }
            label_c = if (hot) blend(accent, fg, 0.25) else fg_dim;
        },
    }
    if (hot and !clicks_blocked) wantCursor(.pointing_hand);
    const fs = btnFont(r.height);
    const tw = measure(label, fs);
    const nudge: f32 = if (down) 1 else 0;
    text(label, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - @as(f32, @floatFromInt(fs))) / 2 + nudge), fs, label_c);
    return hot and rl.isMouseButtonPressed(.left) and !clicks_blocked;
}

pub fn button(r: Rect, label: [:0]const u8, accent: Color, enabled: bool) bool {
    return buttonEx(r, label, accent, enabled, .tonal);
}

pub fn buttonSolid(r: Rect, label: [:0]const u8, accent: Color, enabled: bool) bool {
    return buttonEx(r, label, accent, enabled, .solid);
}

pub fn buttonGhost(r: Rect, label: [:0]const u8, accent: Color, enabled: bool) bool {
    return buttonEx(r, label, accent, enabled, .ghost);
}

/// The width a tab label wants (tabs render at 13px).
pub fn tabW(label: [:0]const u8) f32 {
    return @as(f32, @floatFromInt(measure(label, 13))) + 26;
}

/// A tab in a tab strip: active = a soft accent pill (works on ANY backdrop — the old bg-fill pill
/// vanished on same-color panels); hover = a quiet highlight. Minimal: no underline.
pub fn tab(r: Rect, label: [:0]const u8, active: bool) bool {
    const hot = mouse.over(r);
    const rn = roundnessFor(r, @min(8.0, r.height * 0.32));
    if (active) {
        rl.drawRectangleRounded(r, rn, 8, withAlpha(blue, 36));
    } else if (hot) {
        rl.drawRectangleRounded(r, rn, 8, withAlpha(bg_hl, 200));
    }
    const c = if (active) fg else if (hot) fg_dim else comment;
    const tw = measure(label, 13);
    text(label, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 13) / 2), 13, c);
    if (hot and !active and !clicks_blocked) wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left) and !clicks_blocked;
}

/// A titlebar glyph button (minimize / close). `danger` tints the hover red. Returns true on click.
pub fn winButton(r: Rect, glyph: [:0]const u8, danger: bool) bool {
    const hot = mouse.over(r);
    if (hot) rl.drawRectangleRec(r, if (danger) withAlpha(red, 200) else withAlpha(bg_hl, 220));
    const c = if (hot) (if (danger) bg_dark else fg) else fg_dim;
    const tw = measure(glyph, 15);
    text(glyph, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 15) / 2), 15, c);
    if (hot) wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

/// The nl-veil mark: use assets/icon.png when available; fall back to the procedural bust if loading fails.
/// cx,cy is the center; `s` the half-size.
pub fn drawMark(cx: f32, cy: f32, s: f32, tile: bool) void {
    if (tile) rl.drawRectangleRounded(.{ .x = cx - s, .y = cy - s, .width = s * 2, .height = s * 2 }, 0.32, 8, bg_hl);

    ensureMarkTexture();
    if (mark_tex) |tex| {
        const src = Rect{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) };
        const dst = Rect{ .x = cx - s, .y = cy - s, .width = s * 2, .height = s * 2 };
        rl.drawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        return;
    }

    const fig = magenta;
    // shoulders / cloak: a broad rounded mound, clearly wider than the head (the "person" read)
    rl.drawRectangleRounded(.{ .x = cx - s * 0.92, .y = cy + s * 0.06, .width = s * 1.84, .height = s * 0.98 }, 0.75, 10, fig);
    // head
    rl.drawCircle(@intFromFloat(cx), @intFromFloat(cy - s * 0.44), s * 0.38, fig);
}

/// Click-to-cycle selector (immediate-mode, no popup z-order): shows the current value; left-click →
/// next, right-click → previous. Returns the delta (-1/0/+1) for the caller to apply. Good for small
/// option sets (provider, style, minutes, mode) without a floating list.
pub fn cycle(r: Rect, label: [:0]const u8, value: [:0]const u8, focused: bool) i32 {
    panelBordered(r, bg, if (focused) blue else border);
    text(label, @intFromFloat(r.x + 12), @intFromFloat(r.y + 7), 11, comment);
    textClip(value, @intFromFloat(r.x + 12), @intFromFloat(r.y + 22), 14, fg, @intFromFloat(r.width - 48));
    // chevrons
    const hot = mouse.over(r);
    text(z("<", .{}), @intFromFloat(r.x + r.width - 36), @intFromFloat(r.y + (r.height - 14) / 2), 14, if (hot) blue else comment);
    text(z(">", .{}), @intFromFloat(r.x + r.width - 18), @intFromFloat(r.y + (r.height - 14) / 2), 14, if (hot) blue else comment);
    if (!hot) return 0;
    wantCursor(.pointing_hand);
    if (rl.isMouseButtonPressed(.left)) return 1;
    if (rl.isMouseButtonPressed(.right)) return -1;
    return 0;
}

/// A labeled checkbox toggle. Returns true on click (caller flips the bool).
pub fn checkbox(r: Rect, label: [:0]const u8, on: bool) bool {
    const hot = mouse.over(r) and !clicks_blocked;
    const box = Rect{ .x = r.x, .y = r.y + (r.height - 18) / 2, .width = 18, .height = 18 };
    const rn = roundnessFor(box, 5);
    rl.drawRectangleRounded(box, rn, 8, if (on) withAlpha(green, 60) else if (hot) bg_hl else bg);
    rl.drawRectangleRoundedLinesEx(box, rn, 8, 1.0, if (on) green else if (hot) fg_dim else border);
    if (on) text(z("x", .{}), @intFromFloat(box.x + 5), @intFromFloat(box.y + 2), 14, green);
    text(label, @intFromFloat(r.x + 26), @intFromFloat(r.y + (r.height - 13) / 2), 13, if (on) fg else if (hot) fg else fg_dim);
    if (hot) wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

/// A small +/- stepper for an integer in [lo,hi]. Returns the new value.
pub fn stepper(r: Rect, label: [:0]const u8, v: i32, lo: i32, hi: i32) i32 {
    panelBordered(r, bg, border);
    text(label, @intFromFloat(r.x + 12), @intFromFloat(r.y + 7), 11, comment);
    text(z("{d}", .{v}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 22), 15, fg);
    const bh = @min(r.height - 12, 28.0);
    const by = r.y + (r.height - bh) / 2;
    const minus = Rect{ .x = r.x + r.width - 64, .y = by, .width = 28, .height = bh };
    const plus = Rect{ .x = r.x + r.width - 32, .y = by, .width = 28, .height = bh };
    var nv = v;
    if (button(minus, z("-", .{}), blue, v > lo)) nv = @max(lo, v - 1);
    if (button(plus, z("+", .{}), blue, v < hi)) nv = @min(hi, v + 1);
    return nv;
}

test "foldAscii collapses newlines and transliterates Unicode punctuation (fixes overlap + '?' tofu)" {
    var buf: [256]u8 = undefined;
    // newlines/tabs -> spaces so a multi-line goal never draws as overlapping lines
    {
        const n = foldAscii(&buf, "line one\nline two\tend");
        try std.testing.expectEqualStrings("line one line two end", buf[0..n]);
    }
    // em/en dash + smart quotes + nbsp + bullet + ellipsis -> ASCII (no '?')
    {
        const n = foldAscii(&buf, "Clean\u{2011}Code \u{201c}Tips\u{201d}\u{a0}here\u{2014}now\u{2022}\u{2026}");
        try std.testing.expectEqualStrings("Clean-Code \"Tips\" here-now*...", buf[0..n]);
    }
    // printable Latin-1 (accents) survive; emoji/other are dropped, never tofu
    {
        const n = foldAscii(&buf, "caf\u{e9} \u{1f600}ok");
        try std.testing.expectEqualStrings("caf\u{e9} ok", buf[0..n]);
    }
}
