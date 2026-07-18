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
