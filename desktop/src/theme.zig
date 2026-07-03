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

/// One shared scratch buffer for null-terminating dynamic text before handing it to raylib's C API.
/// UI is single-threaded (main thread only), so a static buffer is safe and avoids per-frame allocation.
var zbuf: [4096]u8 = undefined;
pub fn z(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(&zbuf, fmt, args) catch {
        zbuf[0] = 0;
        return zbuf[0..0 :0];
    };
}
/// Null-terminate a runtime slice (clipped) for the C text API — a second buffer so a label and its
/// value can be live at once without one clobbering the other.
var zbuf2: [4096]u8 = undefined;
pub fn zs(s: []const u8) [:0]const u8 {
    const n = @min(s.len, zbuf2.len - 1);
    @memcpy(zbuf2[0..n], s[0..n]);
    zbuf2[n] = 0;
    return zbuf2[0..n :0];
}

pub fn text(s: [:0]const u8, x: i32, y: i32, size: i32, c: Color) void {
    rl.drawText(s, x, y, size, c);
}

/// Left-aligned label, clipped to max_w px with an ellipsis — the workhorse for rows that must not overflow.
pub fn textClip(s: []const u8, x: i32, y: i32, size: i32, c: Color, max_w: i32) void {
    var n = @min(s.len, zbuf2.len - 1);
    @memcpy(zbuf2[0..n], s[0..n]);
    zbuf2[n] = 0;
    while (n > 1 and rl.measureText(zbuf2[0..n :0], size) > max_w) {
        n -= 1;
        zbuf2[n] = 0;
        if (n > 2) {
            zbuf2[n - 1] = '.';
            zbuf2[n - 2] = '.';
        }
    }
    rl.drawText(zbuf2[0..n :0], x, y, size, c);
}

pub fn measure(s: [:0]const u8, size: i32) i32 {
    return rl.measureText(s, size);
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
    const tw = rl.measureText(label, 13);
    rl.drawText(label, @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2), @intFromFloat(r.y + (r.height - 13) / 2), 13, tc);
    return enabled and mouse.over(r) and rl.isMouseButtonPressed(.left);
}

/// A tab pill in the top tabline. Returns true when clicked.
pub fn tab(r: Rect, label: [:0]const u8, active: bool) bool {
    if (active) rl.drawRectangleRounded(r, 0.2, 6, bg);
    const hot = mouse.over(r);
    const c = if (active) fg else if (hot) fg_dim else comment;
    rl.drawText(label, @intFromFloat(r.x + 10), @intFromFloat(r.y + (r.height - 13) / 2), 13, c);
    return mouse.over(r) and rl.isMouseButtonPressed(.left);
}
