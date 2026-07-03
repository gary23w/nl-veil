//! theme.zig — the nl-veil visual language for the desktop shell.
//! Palette is the exact Tokyo Night set from web/public/styles.css so veil-desk and the web UI read as
//! one product. Everything here is immediate-mode: no retained widget tree, just draw + hit-test helpers
//! called each frame against the raylib backend, so the whole UI is a pure function of AppState.

const std = @import("std");
const rl = @import("raylib");

pub const Color = rl.Color;
pub const Rect = rl.Rectangle;
pub const Vec2 = rl.Vector2;

fn hex(comptime s: []const u8) Color {
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch 0;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch 0;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch 0;
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

// Tokyo Night — mirrors :root in styles.css.
pub const bg = hex("1a1b26");
pub const bg_dark = hex("16161e");
pub const bg_hl = hex("1f2335");
pub const bg_sel = hex("283457");
pub const fg = hex("c0caf5");
pub const fg_dim = hex("a9b1d6");
pub const comment = hex("565f89");
pub const border = hex("292e42");
pub const blue = hex("7aa2f7");
pub const cyan = hex("7dcfff");
pub const green = hex("9ece6a");
pub const magenta = hex("bb9af7");
pub const orange = hex("ff9e64");
pub const red = hex("f7768e");
pub const yellow = hex("e0af68");
pub const teal = hex("2ac3de");

pub fn withAlpha(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
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
    const n = @min(s.len, b.len - 1);
    @memcpy(b[0..n], s[0..n]);
    b[n] = 0;
    return b[0..n :0];
}

// The loaded fonts (real TTFs, loaded at startup). `ui_font` is proportional (labels, buttons, headers);
// `mono_font` is fixed-width for the log console so its columns line up. Until set, fall back to raylib's
// default. Drawing goes through drawTextEx for kerning + antialiasing.
var ui_font: ?rl.Font = null;
var mono_font: ?rl.Font = null;
pub fn setFont(f: rl.Font) void {
    ui_font = f;
}
pub fn setMono(f: rl.Font) void {
    mono_font = f;
}
fn theFont() rl.Font {
    return ui_font orelse (rl.getFontDefault() catch unreachable);
}
fn theMono() rl.Font {
    return mono_font orelse theFont();
}
// Minimal extra tracking — a real TTF already carries its own advances; too much spacing hurts readability.
fn spacingFor(size: i32) f32 {
    return @max(0.3, @as(f32, @floatFromInt(size)) / 28.0);
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
    var n = @min(s.len, b.len - 1);
    @memcpy(b[0..n], s[0..n]);
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
    var n = @min(s.len, b.len - 1);
    @memcpy(b[0..n], s[0..n]);
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
    rl.drawRectangleRounded(r, 0.06, 6, fill);
}

pub fn panelBordered(r: Rect, fill: Color, line: Color) void {
    rl.drawRectangleRounded(r, 0.06, 6, fill);
    rl.drawRectangleRoundedLinesEx(r, 0.06, 6, 1.0, line);
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

/// A button; returns true on click. `accent` tints the hover fill + left edge so primary/danger/ghost
/// buttons read differently without a separate widget per kind.
pub fn button(r: Rect, label: [:0]const u8, accent: Color, enabled: bool) bool {
    const hot = enabled and mouse.over(r);
    const fill = if (!enabled) bg_hl else if (hot) withAlpha(accent, 40) else bg_hl;
    rl.drawRectangleRounded(r, 0.14, 6, fill);
    if (hot) rl.drawRectangleRoundedLinesEx(r, 0.14, 6, 1.0, accent);
    const tc = if (!enabled) comment else if (hot) accent else fg;
    const tw = measure(label, 14); // the loaded TTF — NOT raylib's blocky default (the "ugly button font")
    text(label, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 14) / 2), 14, tc);
    return enabled and mouse.over(r) and rl.isMouseButtonPressed(.left);
}

/// A tab in the tab strip: active gets a filled pill + an accent underline, the nl-veil web-UI look.
pub fn tab(r: Rect, label: [:0]const u8, active: bool) bool {
    const hot = mouse.over(r);
    if (active) {
        rl.drawRectangleRounded(.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, 0.18, 6, bg);
        rl.drawRectangle(@intFromFloat(r.x + 8), @intFromFloat(r.y + r.height - 3), @intFromFloat(r.width - 16), 2, blue);
    } else if (hot) {
        rl.drawRectangleRounded(r, 0.18, 6, withAlpha(bg_hl, 160));
    }
    const c = if (active) fg else if (hot) fg_dim else comment;
    const tw = measure(label, 14);
    text(label, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 14) / 2), 14, c);
    return mouse.over(r) and rl.isMouseButtonPressed(.left);
}

/// A titlebar glyph button (minimize / close). `danger` tints the hover red. Returns true on click.
pub fn winButton(r: Rect, glyph: [:0]const u8, danger: bool) bool {
    const hot = mouse.over(r);
    if (hot) rl.drawRectangleRec(r, if (danger) withAlpha(red, 200) else withAlpha(bg_hl, 220));
    const c = if (hot) (if (danger) bg_dark else fg) else fg_dim;
    const tw = measure(glyph, 15);
    text(glyph, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 15) / 2), 15, c);
    return hot and rl.isMouseButtonPressed(.left);
}

/// The nl-veil mark: a hooded shadow-figure in a rounded tile — the same silhouette the CLI uses, drawn
/// with primitives (no asset needed). cx,cy is the tile center; `s` the tile half-size.
pub fn drawMark(cx: f32, cy: f32, s: f32, tile: bool) void {
    if (tile) rl.drawRectangleRounded(.{ .x = cx - s, .y = cy - s, .width = s * 2, .height = s * 2 }, 0.32, 8, bg_hl);
    const fig = magenta;
    // hood/head: a circle
    rl.drawCircle(@intFromFloat(cx), @intFromFloat(cy - s * 0.34), s * 0.36, fig);
    // shoulders/cloak: a downward triangle-ish body via a rounded rect tapering — approximate with a
    // trapezoid drawn as a triangle fan of two triangles.
    const bw = s * 0.98;
    const top = cy - s * 0.02;
    const bot = cy + s * 0.62;
    rl.drawTriangle(.{ .x = cx, .y = top - s * 0.3 }, .{ .x = cx - bw, .y = bot }, .{ .x = cx + bw, .y = bot }, fig);
    // a darker inner void for the face, giving the "shadowy" read
    rl.drawCircle(@intFromFloat(cx), @intFromFloat(cy - s * 0.34), s * 0.20, bg_dark);
}

/// Click-to-cycle selector (immediate-mode, no popup z-order): shows the current value; left-click →
/// next, right-click → previous. Returns the delta (-1/0/+1) for the caller to apply. Good for small
/// option sets (provider, style, minutes, mode) without a floating list.
pub fn cycle(r: Rect, label: [:0]const u8, value: [:0]const u8, focused: bool) i32 {
    panelBordered(r, bg, if (focused) blue else border);
    text(label, @intFromFloat(r.x + 10), @intFromFloat(r.y + 6), 11, comment);
    textClip(value, @intFromFloat(r.x + 10), @intFromFloat(r.y + 20), 14, fg, @intFromFloat(r.width - 44));
    // chevrons
    const hot = mouse.over(r);
    text(z("<", .{}), @intFromFloat(r.x + r.width - 34), @intFromFloat(r.y + 13), 14, if (hot) blue else comment);
    text(z(">", .{}), @intFromFloat(r.x + r.width - 16), @intFromFloat(r.y + 13), 14, if (hot) blue else comment);
    if (!hot) return 0;
    if (rl.isMouseButtonPressed(.left)) return 1;
    if (rl.isMouseButtonPressed(.right)) return -1;
    return 0;
}

/// A labeled checkbox toggle. Returns true on click (caller flips the bool).
pub fn checkbox(r: Rect, label: [:0]const u8, on: bool) bool {
    const box = Rect{ .x = r.x, .y = r.y + (r.height - 18) / 2, .width = 18, .height = 18 };
    panelBordered(box, if (on) withAlpha(green, 60) else bg, if (on) green else border);
    if (on) text(z("x", .{}), @intFromFloat(box.x + 5), @intFromFloat(box.y + 2), 14, green);
    text(label, @intFromFloat(r.x + 26), @intFromFloat(r.y + (r.height - 13) / 2), 13, fg_dim);
    return mouse.over(r) and rl.isMouseButtonPressed(.left);
}

/// A small +/- stepper for an integer in [lo,hi]. Returns the new value.
pub fn stepper(r: Rect, label: [:0]const u8, v: i32, lo: i32, hi: i32) i32 {
    panelBordered(r, bg, border);
    text(label, @intFromFloat(r.x + 10), @intFromFloat(r.y + 5), 10, comment);
    text(z("{d}", .{v}), @intFromFloat(r.x + 10), @intFromFloat(r.y + 18), 15, fg);
    const minus = Rect{ .x = r.x + r.width - 60, .y = r.y + 6, .width = 26, .height = r.height - 12 };
    const plus = Rect{ .x = r.x + r.width - 30, .y = r.y + 6, .width = 26, .height = r.height - 12 };
    var nv = v;
    if (button(minus, z("-", .{}), blue, v > lo)) nv = @max(lo, v - 1);
    if (button(plus, z("+", .{}), blue, v < hi)) nv = @min(hi, v + 1);
    return nv;
}
