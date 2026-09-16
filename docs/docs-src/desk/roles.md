# roles

**File:** `desk/src/roles.zig`  
**Module:** `desk`  
**Description:** The built-in catalog of prebuilt chat roles, embedded from `desk/roles.json` at build time and parsed once for the Chat tab's role picker.

---

## Purpose Summary

A role is an operating doctrine a user can hand a chat with one click: the desk sends the picked role's `prompt` as the conversation's next message, so the AI works under it from that turn on. The catalog lives in `desk/roles.json` and is compiled into the binary, the same way assets.zig embeds the icons and fonts, so a released bundle has the roles wherever it is launched from and there is no working-directory-relative file to miss. Editing the JSON and rebuilding updates the picker.

## Key Exports

- `MAX_PROMPT` (4096) — the most bytes a role prompt may hold, equal to the capacity of `store.ChatCommand.text`; written as a literal rather than imported so the module has no dependencies
- `RAW` — the embedded JSON, `@embedFile("desk_roles_json")`
- `Role` — `{ id, label, category, blurb, prompt }`, all `[]const u8`
- `all()` — the parsed role list, or an empty slice if the embedded JSON does not parse; parsed on the first call and cached for the life of the process

## Dependencies

- std (`std.json.parseFromSlice`, `std.heap.page_allocator`)
- the `desk_roles_json` anonymous import, registered by `addDeskAssets` in `build.zig` (from `desk/roles.json`, for the merged `veil` binary) and in `desk/build.zig` (from `roles.json`, for the standalone desk exe and its test module)

## Usage Context

`desk/src/main.zig` imports it as `roles_mod`. `drawChatCenter` draws a "+ give the veil a role" link under the chat input only while the chat is not busy, not looping, shows no status and `roles_mod.all().len > 0`; clicking it opens the `.chat_role` dropdown. `flushChatRoleDropdown`, called last in `drawChat` so the list sits on top, shows the role labels through `drawList` (at most 32, the size of its label array) and on a pick pushes `store_mod.mkChatCmd(.send, "", list[chosen].prompt)`, the same `.send` command the Send button pushes, then sets `ui.chat_follow`. The desk reads only `label` and `prompt`; `category` and `blurb` are parsed and tested but not displayed. `desk/src/tests.zig` registers the module's test.

## Notable Implementation Details

- **The size test is the guard.** `mkChatCmd` copies at most 4096 bytes of text, so a longer prompt would be cut off without warning and the AI would get half a doctrine. The test fails the desk suite if any prompt is longer than `MAX_PROMPT`, if any field is empty, if the catalog is empty, or if two roles share an `id`. It parses with `std.testing.allocator` and deinits, which also proves the parse does not leak.
- **Parsed once, never freed.** `all()` runs on every frame the idle composer is drawn, so the result is cached in `g_parsed`. The `Role` strings point into the embedded bytes and the parse arena, so the `Parsed` value has to stay alive for them to stay valid. `page_allocator` rather than libc keeps the parse working in the standalone desk build.
- **Fails open.** `g_tried` is set before the first parse, so after a failure every later call returns an empty slice without retrying: a corrupt embed hides the picker instead of crashing the desk or re-parsing each frame. `ignore_unknown_fields` lets the JSON carry extra keys, but no `Role` field has a default, so one role missing a field fails the whole parse and hides every role. The test parses with the same options and fails on the same input.
- **Main thread only.** There is no lock. The picker is drawn and clicked on the GL thread, the module's only caller.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
