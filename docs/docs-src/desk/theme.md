# theme

**File:** `desk/src/theme.zig`  
**Module:** `desk`  
**Description:** The nl-veil desktop shell's visual language — dark/light palette tokens plus stateless draw-and-hit-test widget helpers layered over raylib.

---

## Purpose Summary

Defines veil-desk's entire visual language: the Tokyo Night color scheme (the dark palette mirrored from web/public/styles.css so the native app and web UI read as one product, plus a light palette tuned by hand to the same language), a single spacing/sizing token scale, and a library of immediate-mode draw + hit-test helpers (text, panels, buttons, tabs, checkbox, stepper, cycle selector, window buttons, brand mark). It is retained-tree-free immediate-mode UI: the widget helpers hold no per-widget state and hit-test against the live mouse each frame, so the interface is a pure function of AppState (over the module's global theme/cursor state).

## Key Exports

- `setScheme` / `setSchemeFromInt` / `getScheme` / `schemeInt` — swap the active dark/light Palette into the public mutable color globals (bg, fg, blue, red, ...) that every widget reads (setScheme early-returns if unchanged)
- `z` / `zs` — format/copy a string into the next slot of a 24-entry ring of 2 KB scratch buffers, returning a sentinel-terminated `[:0]const u8` for raylib (zs also runs foldAscii)
- `foldAscii` — fold arbitrary (LLM-authored) UTF-8 to renderable single-line text: control bytes→space, transliterate the Unicode punctuation the atlas lacks, keep Latin-1/Greek/math/atlas-carried glyphs verbatim, drop emoji/CJK
- `text` / `measure` / `textClip` / `textMono` / `measureMono` / `textMonoClip` — proportional and monospace draw/measure, with an ellipsis variant (textClip) and hard-clip variants
- `buttonEx` (+ `button` / `buttonSolid` / `buttonGhost`, `btnFont`, `btnW`) — one button widget in three weights (solid/tonal/ghost); the solid weight gets luma-based auto-contrast labels, all weights get press feedback
- `tab` / `tabW` / `winButton` / `checkbox` / `stepper` / `cycle` — immediate-mode tab pill, titlebar glyph button, toggle, integer +/- stepper, and click-to-cycle selector; they return a click bool, the new integer value (stepper), or a -1/0/+1 delta (cycle)
- `panel` / `panelBordered` / `fillRect` / `hline` / `statusDot` — rounded panel and primitive draw helpers (plus `hovering` hit-test)
- `drawMark` — brand mark from assets/icon.png with a procedural magenta-bust fallback
- `wantCursor` / `applyCursor` — per-frame last-writer-wins OS cursor request
- `setBlockClicks` — suppress covered-widget clicks while an overlay is open
- `setFont` / `setMono` / `deinit` — install the loaded TTFs and free the mark texture
- `withAlpha` — color alpha override; plus design tokens PAD/PAD_IN/GAP/BTN_SM/BTN_MD/BTN_LG/FIELD_H

## Dependencies

- std (std.fmt.bufPrintZ, std.unicode utf8 decode helpers, std.testing)
- raylib (aliased `rl`) — Color/Rectangle/Vector2 types, drawTextEx/measureTextEx, rounded-rect and primitive draws, mouse/cursor input, image+texture loading
- log.zig — trace logging on scheme/font/texture lifecycle events
- web/public/styles.css — source of truth the dark palette's hex values mirror (co-maintained in comments, not imported)
- main.glyph_set — the font atlas glyph coverage that foldAscii's keep/drop rules are hand-synced against (referenced in comments, not imported)

## Usage Context

Loaded once at startup: main installs the two TTFs via setFont/setMono and picks a scheme via setScheme/setSchemeFromInt (the module default is .light — the scheme var and color globals start on light_palette). Thereafter every tab/screen renderer calls these helpers each frame to draw and hit-test its UI against the current mouse. Per frame, main calls applyCursor() once to commit the winning cursor request, and renderers wrap overlay draws in setBlockClicks(true/false) so an open dropdown consumes clicks instead of the widgets beneath it. On shutdown main calls deinit() to unload the mark texture.

## Notable Implementation Details

The RING OF 24 SCRATCH BUFFERS (ZBUFS=24, each [2048]u8) is the load-bearing trick: Zig evaluates call arguments left-to-right, so a single static buffer made `text(z("desk"), x + measure(z("veil")), ...)` render "veil veil" and an array of four z()'d tab labels all aliased the last one ("Settings"). The ring keeps many z() results live simultaneously; it is NOT thread-safe and assumes the single-threaded UI thread, and >24 live results silently wrap (zi is mod-24). Theme state is global mutable module vars: the 16 public color slots (bg, bg_dark, bg_hl, bg_sel, fg, fg_dim, comment, border, blue, cyan, green, magenta, orange, red, yellow, teal) are overwritten in place by applyPalette on setScheme rather than passed around — widgets read the globals directly. foldAscii is a hand-tuned transliteration table whose keep/drop decisions are coupled to the actual font atlas (main.glyph_set): it passes Greek, sub/superscripts, and a curated set of math operators/relations plus the primary bullet and open/filled circles VERBATIM because those glyphs were added to the atlas. It folds to ASCII only what the atlas lacks: em/en dashes and the Unicode minus (U+2212) to '-', smart quotes to ' and \", ellipsis (U+2026) to '...', nbsp and other Unicode spaces to a single space, zero-width chars to nothing, the atlas-missing bullets (U+2023/U+2027/U+25AA) to '*', checkmarks (U+2713/2714) to 'v', and the double-left arrow (U+21D0) to '<-' — but it KEEPS verbatim the single-glyph arrows (U+2190–2193, U+21D2) and the bullet U+2022, keeps printable Latin-1 (U+00A1–00FF, minus soft-hyphen U+00AD→'-' and nbsp U+00A0→space) verbatim, and DROPS anything else (emoji/CJK) rather than showing tofu '?'; it also collapses every control byte (\n \r \t, DEL) to a single space so multi-line LLM text never draws as overlapping lines. Cursor feedback is request-based, last-writer-wins: widgets call wantCursor while hot, later draws (overlays) naturally override, and applyCursor touches the OS cursor only on an actual change, resetting the want to .default each frame. clicks_blocked gates button()/checkbox()/tab() press returns so overlay clicks don't double-fire covered widgets (winButton and cycle do not consult it). Solid-button labels get auto-contrast via luma(accent) >= 150 (dark label on light pastels, light label on saturated darks) so one code path works in both schemes. roundnessFor converts a PIXEL corner radius into raylib's short-side-relative roundness ratio so big buttons and small chips share one corner language. The brand mark lazily loads assets/icon.png from four candidate relative paths (attempt guarded by mark_tex_attempted so a failed load isn't retried every frame), runs scrubTransparentRgb to zero the RGB of fully-transparent pixels (kills bilinear-filter fringing), and falls back to a procedural magenta shoulders+head bust if no PNG loads. Proportional text uses spacingFor(size) ≈ size/64 tracking while mono uses a fixed 0.5 advance so console columns align. An inline unit test pins foldAscii's newline/Unicode/emoji behavior.

---

*Documentation generated for nl-veil — desk/theme.zig source analysis.*
