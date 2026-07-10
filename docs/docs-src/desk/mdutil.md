# mdutil

**File:** `desk/src/mdutil.zig`  
**Module:** `desk`  
**Description:** The raylib-free half of veil-desk's chat markdown renderer: block-type predicates, GFM table row parsing, a LaTeX-ish math-to-unicode pass, and inline-markdown stripping — split out of main.zig so it can be unit-tested standalone.

---

## Purpose Summary

Provides the pure string-processing layer of the desktop chat pane's markdown renderer. It classifies markdown lines (horizontal rules, table separators), splits table rows into cells, converts LaTeX-ish math into readable unicode/ASCII, and flattens inline markdown (links, bold/italic/code, <br>) into plain text. It is deliberately kept free of raylib so it can be exercised with `zig test`, while the actual glyph drawing (renderMsg/renderTable) lives in main.zig and calls into these functions.

## Key Exports

- `mdstarts(hay, needle)` — thin wrapper over std.mem.startsWith for prefix checks
- `hasPipe(tl)` — true if a non-empty line contains a '|' (candidate table row)
- `isHr(tl)` — recognizes a markdown horizontal rule: 3+ of a single '-'/'*'/'_' with spaces allowed, nothing else
- `isTableSep(tl)` — recognizes the |---|:--:| header-separator row (only |,-,:,space chars and at least one '-')
- `tableInner(tl)` — strips the outer leading/trailing pipes so a plain '|' split yields exactly the cells
- `mathToUnicode(dst, src) usize` — transforms LaTeX-ish math in src into readable unicode/ASCII in dst, returns bytes written (bounded to dst.len)
- `hasMath(s) bool` — cheap pre-check (scans for '$','\\','^') so pure prose can skip the math pass
- `cleanInline(dst, src) usize` — resolves inline markdown to plain text (runs the math pass first, then strips emphasis/code/links/<br>), returns bytes written

## Dependencies

- std (std.mem, std.unicode.utf8Encode, std.testing)
- main.zig — the raylib-linked caller; per its module comment renderMsg/renderTable stay in main.zig and call these predicates and cleanInline before drawing
- theme.foldAscii + the font atlas — noted in comments as extended to carry the greek/operator unicode this file emits

## Usage Context

Called by the veil-desk desktop chat pane's message drawing code in main.zig while rendering assistant/user markdown. Per line, main.zig uses isHr/hasPipe/isTableSep/tableInner to decide block layout (rules, tables), then feeds cell/line text through cleanInline to get display-ready plain text (which internally runs mathToUnicode when hasMath is true). The split exists so this logic is unit-testable without raylib — the file ships its own test suite covering rules, table round-trips, math, and inline cleanup.

## Notable Implementation Details

All output is written into caller-provided fixed buffers via bounded putB/putS/putCp helpers that silently stop at dst.len — nothing allocates and overflow truncates rather than corrupting. cleanInline uses a 4096-byte stack scratch (mbuf) for the math pass and only runs math when trimmed.len <= 3500 && hasMath; oversized lines skip math entirely to avoid truncation risk. The math engine (writeMath) is a recursive descent state machine with an in_math flag toggled by $, $$, \\( \\[ \\) \\] delimiters and a recursion depth cap of 8 (guarding \\frac and unknown-macro unwrapping). Its central heuristic distinguishes math from currency: an opening '$' is treated as math only if the span to the next '$' carries a math signal (\\ ^ _ { }) or starts with a letter/backslash — so "$2^{32}$" converts but "$5 and $10" stays literal. Crucially, super/subscripts convert ONLY inside a math span: a bare "2^32" or "x_i" in prose is left literal (this fixed an "exponent-corruption" bug), and subscripts additionally require the '_' to be attached to an alnum at a word boundary so snake_case (file_name, std_lib) survives. Unknown bare \\cmd is emitted VERBATIM with its backslash — deliberately preserving Windows paths (C:\\Users), regexes (\\d+), and escapes (\\t) — while only the known math_macros table (a linear-scanned array of ~80 LaTeX names matched on the WHOLE letter-run so "le"/"leq"/"leftarrow" never collide) transforms. \\frac becomes (a)/(b), \\sqrt{x} becomes √(x), unknown \\cmd{arg} (e.g. \\text, \\mathbb) unwraps to just arg. emitScript degrades gracefully: full unicode super/subscripts when every char maps, else readable ASCII fallbacks (^x, ^(...), _q, _(...)). cleanInline's emphasis stripping is word-adjacency-gated (a marker is only stripped if prev or next is alnum, with a snake_case exception for '_'), which is what lets "a * b" and file_name survive while **bold**/_italic_/__bold__ get flattened; it also collapses space runs and right-trims. The file carries an extensive inline test suite (isHr, isTableSep, tableInner, cleanInline, mathToUnicode, and a full GFM table-row round-trip) documenting the regression cases it guards.

---

*Documentation generated for nl-veil — desk/mdutil.zig source analysis.*
