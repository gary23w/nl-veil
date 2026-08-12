//! roles.zig — the built-in "prebuilt roles" catalog: doctrines a user can hand a fresh chat with one click.
//!
//! Sourced from desk/roles.json, EMBEDDED at build time (build.zig + ../build.zig register it as
//! "desk_roles_json", exactly like the icons/fonts in assets.zig) so a released bundle carries the roles
//! wherever it is launched from — no CWD-relative file to misplace. Edit desk/roles.json, rebuild, and the
//! Chat tab's role picker updates.
//!
//! On click the picked role's `prompt` is sent as the conversation's FIRST message (a .send command), so the
//! AI begins operating under the doctrine immediately. That is why MAX_PROMPT below mirrors the .send ring
//! buffer (store.ChatCommand.text = [4096]u8): a prompt that overran it would be SILENTLY truncated mid-send,
//! and a half-doctrine is worse than none. The test at the bottom fails the build before that can ship.
//!
//! Parsed ONCE, lazily, on the main/GL thread (the only caller — the picker is drawn there and the click
//! runs there). The parse is cached for the process lifetime and never freed: the Role strings alias the
//! embedded bytes / the parse arena, so keeping the Parsed value alive is what keeps them valid
//! (parseFromSlice aliasing — see the neuron-db json-alias note). A corrupt embed fails open to an empty
//! list rather than crashing the desk: the picker simply does not appear.

const std = @import("std");

/// The maximum bytes a role prompt may occupy, = store.ChatCommand.text's capacity. Mirrored as a literal
/// rather than imported to keep this module dependency-free; the test asserts every shipped role fits, and
/// if store's buffer ever shrinks below this the desk suite's own send-path tests are where that surfaces.
pub const MAX_PROMPT: usize = 4096;

pub const RAW: []const u8 = @embedFile("desk_roles_json");

pub const Role = struct {
    id: []const u8,
    label: []const u8,
    category: []const u8,
    blurb: []const u8,
    prompt: []const u8,
};

const Doc = struct { roles: []Role };

var g_parsed: ?std.json.Parsed(Doc) = null;
var g_tried = false;

/// The parsed role list, or an empty slice if the embedded JSON is unusable. Cached process-lifetime.
/// Main-thread only (the picker draws and dispatches on the GL thread); no lock, by that contract.
/// page_allocator, not libc: this must work in the standalone desk build too, and the parse runs once.
pub fn all() []const Role {
    if (g_parsed) |p| return p.value.roles;
    if (g_tried) return &.{}; // a prior parse failed — do not thrash the allocator every frame
    g_tried = true;
    const parsed = std.json.parseFromSlice(Doc, std.heap.page_allocator, RAW, .{ .ignore_unknown_fields = true }) catch return &.{};
    g_parsed = parsed;
    return parsed.value.roles;
}

test "roles.json parses, and every role is well-formed and fits the send buffer" {
    // Uses the testing allocator and DOES deinit (unlike production, which caches for the process lifetime),
    // so this both validates the shipped catalog and proves the parse has no leak.
    const parsed = try std.json.parseFromSlice(Doc, std.testing.allocator, RAW, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const roles = parsed.value.roles;
    try std.testing.expect(roles.len >= 1);
    for (roles, 0..) |r, i| {
        // Every field is load-bearing: an empty id/label/prompt would ship a blank or dead menu entry.
        try std.testing.expect(r.id.len > 0);
        try std.testing.expect(r.label.len > 0);
        try std.testing.expect(r.category.len > 0);
        try std.testing.expect(r.blurb.len > 0);
        try std.testing.expect(r.prompt.len > 0);
        // THE load-bearing assertion (see the header): a prompt that overruns the .send buffer is truncated
        // silently at click time, handing the AI half a doctrine. Fail the build here instead.
        try std.testing.expect(r.prompt.len <= MAX_PROMPT);
        // ids must be unique — the picker keys off them, and a dupe would make one role unreachable.
        for (roles[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, prev.id, r.id));
    }
}
