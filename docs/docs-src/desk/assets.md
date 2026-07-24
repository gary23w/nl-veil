# assets

**File:** `desk/src/assets.zig`  
**Module:** `desk`  
**Description:** The desk's bundled art and type, compiled INTO the exe — bytes in the binary cannot be misplaced.

---

## Purpose Summary

Every asset here used to be loaded from a CWD-relative path ("assets/icon48x48.png", "desk/assets/...", "../assets/..."). Those probes resolve against the process's working directory, NOT the exe's directory, so a released bundle launched from anywhere but the repo root missed every candidate and silently degraded — generic system tray icon, procedural bust for the window/taskbar icon, a vector figure instead of the veil mark, Comic Sans instead of OpenDyslexic. Nothing crashed, which is exactly why it shipped unnoticed. Each accessor is now EMBEDDED-FIRST with the old disk probes kept behind it at the call sites, so a corrupt embed or an unsupported decoder can still fall through to the previous behaviour.

## Key Exports

- `icon16_png` — the brand mark for the titlebar client icon and the chat veil mark; named for its intended DISPLAY size, the source art is 1024×1024 so mipmaps stay crisp
- `icon48_png` — the window/taskbar icon and the Shell_NotifyIcon tray icon (also 1024×1024 source art)
- `dyslexic_regular_ttf` / `dyslexic_bold_ttf` — the shipped OpenDyslexic faces (SIL OFL — see assets/fonts/OFL.txt)
- `iconImage` — decode the window/taskbar/tray icon from the embedded PNG (caller owns the image)
- `markImage` — decode the brand mark, preferring the mark art and falling back to the larger app icon so a decoder failure still yields a real mark
- `dyslexicFont` — rasterize the bundled OpenDyslexic face at a size for a codepoint set; null when no usable atlas, so callers keep their system-font fallbacks

## Dependencies

- `raylib` — `loadImageFromMemory` / `loadFontFromMemory` decoding
- `@embedFile` of the build-registered asset modules (`desk_icon16_png`, `desk_icon48_png`, the two OpenDyslexic ttfs)

## Usage Context

Consumed by desk/src/main.zig (window icon, dyslexic font path), desk/src/theme.zig (the brand mark), and desk/src/tray.zig (the tray icon) — each embedded-first with its old probe chain behind.

## Notable Implementation Details

- NOT embedded on purpose: the regular UI + mono faces. Those resolve ABSOLUTE system paths (C:/Windows/Fonts/…, /System/Library/Fonts/…, /usr/share/fonts/…), which are already CWD-independent and therefore already correct in a bundle — embedding them would cost megabytes for nothing.
- `dyslexicFont` mirrors loadFontEx's contract (null on failure, glyphCount checked) so call sites did not have to change shape.

---

*Case file grounded in the module's `//!` header and public API.*
