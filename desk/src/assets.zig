//! assets.zig — the desk's BUNDLED art and type, compiled INTO the exe.
//!
//! Why embed rather than ship an assets/ dir: every asset here used to be loaded from a CWD-relative path
//! ("assets/icon48x48.png", "desk/assets/...", "../assets/..."). Those probes resolve against the process's
//! working directory, NOT the exe's directory, so a released bundle launched from anywhere but the repo
//! root missed every candidate and silently degraded — generic system tray icon, procedural bust for the
//! window/taskbar icon, a vector figure instead of the veil mark, Comic Sans instead of OpenDyslexic.
//! Nothing crashed, which is exactly why it shipped unnoticed. Bytes in the binary cannot be misplaced.
//!
//! Each accessor is EMBEDDED-FIRST with the old disk probes kept behind it (see the call sites in
//! main.zig / theme.zig / tray.zig): a source checkout that edits desk/assets/ still wins nothing, but a
//! corrupt embed or an unsupported decoder can still fall through to the previous behaviour.
//!
//! NOT embedded on purpose: the regular UI + mono faces. Those resolve ABSOLUTE system paths
//! (C:/Windows/Fonts/calibri.ttf, /System/Library/Fonts/..., /usr/share/fonts/...) which are already
//! CWD-independent and therefore already correct in a bundle. Embedding them would cost megabytes for
//! nothing. Only the faces we actually ship (OpenDyslexic, SIL OFL — see assets/fonts/OFL.txt) are here.

const std = @import("std");
const rl = @import("raylib");

/// The brand mark used for the titlebar client icon and the chat veil mark (theme.drawMark/drawMarkPulse).
/// Named 16x16 for its intended DISPLAY size; the source art is 1024x1024 so mipmaps stay crisp.
pub const icon16_png: []const u8 = @embedFile("desk_icon16_png");
/// The window/taskbar icon and the Shell_NotifyIcon tray icon. Also 1024x1024 source art.
pub const icon48_png: []const u8 = @embedFile("desk_icon48_png");

pub const dyslexic_regular_ttf: []const u8 = @embedFile("desk_opendyslexic_regular_ttf");
pub const dyslexic_bold_ttf: []const u8 = @embedFile("desk_opendyslexic_bold_ttf");

/// Decode the window/taskbar/tray icon from the embedded PNG. Caller owns the image (rl.unloadImage).
pub fn iconImage() ?rl.Image {
    return rl.loadImageFromMemory(".png", icon48_png) catch null;
}

/// Decode the brand mark. Prefers the mark art, falling back to the larger app icon so a decoder failure
/// on one asset still yields a real mark rather than the vector figure.
pub fn markImage() ?rl.Image {
    if (rl.loadImageFromMemory(".png", icon16_png)) |img| return img else |_| {}
    if (rl.loadImageFromMemory(".png", icon48_png)) |img| return img else |_| {}
    return null;
}

/// Rasterize the bundled OpenDyslexic face at `size` for `codepoints`. Mirrors loadFontEx's contract:
/// null when the face did not produce a usable atlas, so callers keep their system-font fallbacks.
pub fn dyslexicFont(bold: bool, size: i32, codepoints: []const i32) ?rl.Font {
    const bytes = if (bold) dyslexic_bold_ttf else dyslexic_regular_ttf;
    if (rl.loadFontFromMemory(".ttf", bytes, size, codepoints)) |f| {
        if (f.glyphCount > 0) return f;
    } else |_| {}
    return null;
}

// ---- tests ---------------------------------------------------------------------------------------------
//
// The failure this file exists to prevent is SILENT — a generic tray icon, a procedural bust, Comic Sans —
// so the embed itself is what has to be pinned: real art and real type, in the binary, at a resolution the
// icon mip chain can use. A build that embedded a placeholder, a Git-LFS pointer, or the same file under
// two names would look exactly like a working build until someone squinted at the taskbar.

/// Width/height straight out of a PNG's IHDR (always the first chunk, always at a fixed offset), so the
/// resolution check needs no decoder and no window.
fn pngHeader(bytes: []const u8) ?struct { w: u32, h: u32, depth: u8, color_type: u8 } {
    if (bytes.len < 26) return null;
    if (!std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .w = std.mem.readInt(u32, bytes[16..20], .big),
        .h = std.mem.readInt(u32, bytes[20..24], .big),
        .depth = bytes[24],
        .color_type = bytes[25],
    };
}

/// A conservative view of a decoded image's pixels: 3 bytes per pixel is the floor for any uncompressed
/// RGB/RGBA decode, so this can never read past the buffer whatever format raylib chose.
fn pixelBytes(img: rl.Image) []const u8 {
    const addr = @intFromPtr(img.data);
    if (addr == 0 or img.width <= 0 or img.height <= 0) return &.{};
    const px: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height));
    const p: [*]const u8 = @ptrFromInt(addr);
    return p[0 .. px * 3];
}

test "the embedded art is real PNG at a resolution the icon mip chain can use" {
    for ([_][]const u8{ icon16_png, icon48_png }) |png| {
        const h = pngHeader(png) orelse return error.TestUnexpectedResult;
        // square and far larger than any display size: both are named for where they are USED (16px mark,
        // 48px tray/taskbar) and are downscaled at load, so a source re-exported at its display size would
        // still "work" while looking soft in every mip.
        try std.testing.expectEqual(h.w, h.h);
        try std.testing.expect(h.w >= 256);
        try std.testing.expectEqual(@as(u8, 8), h.depth);
        try std.testing.expectEqual(@as(u8, 6), h.color_type); // RGBA — these icons need their alpha
        try std.testing.expect(png.len > 100 * 1024); // not a 1x1 placeholder or an LFS pointer file
    }
    // four distinct anonymous imports in build.zig: a copy-paste that pointed two of them at one file
    // would ship the app icon as the brand mark (or one weight of the face as both).
    try std.testing.expect(!std.mem.eql(u8, icon16_png, icon48_png));
    try std.testing.expect(!std.mem.eql(u8, dyslexic_regular_ttf, dyslexic_bold_ttf));
}

test "the embedded faces are real sfnt TrueType, not a stub or a text file" {
    for ([_][]const u8{ dyslexic_regular_ttf, dyslexic_bold_ttf }) |ttf| {
        try std.testing.expect(ttf.len > 100 * 1024);
        // sfnt version 1.0 — the tag stb_truetype needs to see; "OTTO"/"true"/HTML/JSON all fail here
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, ttf[0..4]);
        try std.testing.expect(std.mem.readInt(u16, ttf[4..6], .big) > 0); // numTables
    }
}

test "markImage prefers the mark art, and the icon it falls back to decodes on its own" {
    // Safe without a window: loadImageFromMemory is a CPU-side stb_image decode. Rasterising a FONT is not
    // (loadFontFromMemory uploads a GPU atlas), which is why dyslexicFont() is left to the running app.
    //
    // raylib announces every successful decode on STDOUT, and under `zig build test` stdout IS the test
    // runner's IPC channel (--listen=-): four "INFO: IMAGE: Data loaded successfully" lines in that pipe
    // wedge the build until it is killed, while the same binary run standalone passes. Silence the decoder
    // for the duration — .info is raylib's own default, which main.zig lowers to .warning at startup.
    rl.setTraceLogLevel(.none);
    defer rl.setTraceLogLevel(.info);

    const mark = markImage() orelse return error.TestUnexpectedResult;
    defer rl.unloadImage(mark);
    const icon = iconImage() orelse return error.TestUnexpectedResult;
    defer rl.unloadImage(icon);
    try std.testing.expect(rl.isImageValid(mark) and rl.isImageValid(icon));

    const from_mark_art = rl.loadImageFromMemory(".png", icon16_png) catch return error.TestUnexpectedResult;
    defer rl.unloadImage(from_mark_art);
    const from_app_icon = rl.loadImageFromMemory(".png", icon48_png) catch return error.TestUnexpectedResult;
    defer rl.unloadImage(from_app_icon);
    // both embeds decode standalone, so markImage's second arm is a live fallback and not dead code
    try std.testing.expect(rl.isImageValid(from_mark_art) and rl.isImageValid(from_app_icon));
    // the two are genuinely different art — without this the preference assertion below proves nothing
    try std.testing.expect(!std.mem.eql(u8, pixelBytes(from_mark_art), pixelBytes(from_app_icon)));
    // ORDER: the mark comes from the mark art…
    try std.testing.expect(std.mem.eql(u8, pixelBytes(mark), pixelBytes(from_mark_art)));
    // …and the window/tray icon from the app icon, which is the larger-surface art
    try std.testing.expect(std.mem.eql(u8, pixelBytes(icon), pixelBytes(from_app_icon)));
}
