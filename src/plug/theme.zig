//! theme.zig — the SHARED theme workspace: one canonical palette model + a Lua loader, consumed by
//! every frontend (server /api/v1/themes for the web app, the desk natively, the CLI for listing).
//!
//! A theme is a single `*.lua` file in `<data>/themes/` that returns a table:
//!
//!   return {
//!     id      = "matrix",        -- slug [a-z0-9_-], what gets persisted as "my theme"
//!     name    = "Matrix",        -- display name
//!     dark    = true,            -- dark ground? (web picks its base scheme from this)
//!     mono_ui = true,            -- render the whole UI in the mono/code font (desk + web)
//!     colors  = { bg = "#061106", fg = "#4aff7f", ... },  -- any subset; missing slots default
//!   }
//!
//! The three shipped themes (dark/light/matrix) are SEEDED into the workspace as real files on first
//! boot — the files are the source of truth from then on (edit them, they win). The compiled-in
//! copies here are only the fallback when a seeded file is deleted or unparseable, so the app can
//! never boot themeless. Loading uses a throwaway sandboxed Vm per file: a theme is data, and the
//! sandbox (no io/os.execute/debug, instruction+memory budget) keeps it that way.

const std = @import("std");
const lua = @import("lua.zig");

pub const SLOT_COUNT = 16;
/// Palette slot order — FROZEN: desk theme.zig, web styles.css vars and the JSON endpoint all key
/// off these names. Index order here == desk Palette field order == web --var order.
pub const slot_names = [SLOT_COUNT][:0]const u8{
    "bg", "bg_dark", "bg_hl", "bg_sel", "fg", "fg_dim", "comment", "border",
    "blue", "cyan", "green", "magenta", "orange", "red", "yellow", "teal",
};

pub const ID_MAX = 24;
pub const NAME_MAX = 48;
pub const MAX_THEMES = 32;

pub const Theme = struct {
    id_buf: [ID_MAX]u8 = undefined,
    id_len: u8 = 0,
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: u8 = 0,
    dark: bool = true,
    mono_ui: bool = false,
    /// true when id is one of the shipped trio (dark/light/matrix), regardless of file overrides.
    builtin: bool = false,
    colors: [SLOT_COUNT]u32 = undefined, // 0xRRGGBB

    pub fn id(t: *const Theme) []const u8 {
        return t.id_buf[0..t.id_len];
    }
    pub fn name(t: *const Theme) []const u8 {
        return t.name_buf[0..t.name_len];
    }
    fn setId(t: *Theme, s: []const u8) void {
        t.id_len = @intCast(@min(s.len, ID_MAX));
        @memcpy(t.id_buf[0..t.id_len], s[0..t.id_len]);
    }
    fn setName(t: *Theme, s: []const u8) void {
        t.name_len = @intCast(@min(s.len, NAME_MAX));
        @memcpy(t.name_buf[0..t.name_len], s[0..t.name_len]);
    }
};

pub const ThemeSet = struct {
    items: [MAX_THEMES]Theme = undefined,
    count: usize = 0,
    /// Human-readable notes about skipped/overridden files ("<file>: <reason>" lines).
    report_buf: [1024]u8 = undefined,
    report_len: usize = 0,

    pub fn slice(s: *const ThemeSet) []const Theme {
        return s.items[0..s.count];
    }
    pub fn report(s: *const ThemeSet) []const u8 {
        return s.report_buf[0..s.report_len];
    }
    pub fn byId(s: *const ThemeSet, theme_id: []const u8) ?*const Theme {
        for (s.items[0..s.count]) |*t| {
            if (std.mem.eql(u8, t.id(), theme_id)) return t;
        }
        return null;
    }
    fn note(s: *ThemeSet, comptime fmt: []const u8, args: anytype) void {
        const rest = s.report_buf[s.report_len..];
        const line = std.fmt.bufPrint(rest, fmt ++ "\n", args) catch return;
        s.report_len += line.len;
    }
};

// ---------------------------------------------------------------------------------------------
// Built-in palettes (fallbacks + seed material). Values are the canonical ones the desk shipped
// with — web/public/styles.css mirrors the same hex set.
// ---------------------------------------------------------------------------------------------

const dark_colors = [SLOT_COUNT]u32{
    0x1a1b26, 0x16161e, 0x1f2335, 0x283457, 0xe9edfa, 0xa9b1d6, 0x565f89, 0x292e42,
    0x7aa2f7, 0x7dcfff, 0x9ece6a, 0xbb9af7, 0xff9e64, 0xf7768e, 0xe0af68, 0x2ac3de,
};
const light_colors = [SLOT_COUNT]u32{
    0xf5f7fb, 0xe9edf5, 0xdfe7f4, 0xcfdcf3, 0x14182b, 0x46557a, 0x6d7a99, 0xd3dbe9,
    0x2f6feb, 0x0b84a5, 0x2f8f46, 0x8a3ffc, 0xc27a00, 0xc93a4a, 0xa06a00, 0x0f8a83,
};
const matrix_colors = [SLOT_COUNT]u32{
    0x061106, 0x030a03, 0x0b200e, 0x134020, 0x4aff7f, 0x2fd465, 0x1d9448, 0x15421f,
    0x3bff9d, 0x00ffd0, 0x00ff41, 0xbd66ff, 0xffa028, 0xff4d4d, 0xffd93b, 0x00c9a0,
};

pub const builtin_ids = [3][]const u8{ "dark", "light", "matrix" };

fn builtinTheme(idx: usize) Theme {
    var t = Theme{ .builtin = true };
    switch (idx) {
        0 => {
            t.setId("dark");
            t.setName("Tokyo Night");
            t.dark = true;
            t.mono_ui = false;
            t.colors = dark_colors;
        },
        1 => {
            t.setId("light");
            t.setName("Light");
            t.dark = false;
            t.mono_ui = false;
            t.colors = light_colors;
        },
        else => {
            t.setId("matrix");
            t.setName("Matrix");
            t.dark = true;
            t.mono_ui = true;
            t.colors = matrix_colors;
        },
    }
    return t;
}

/// Legacy desk persistence: settings.theme u8 0/1/2. Kept round-trippable forever.
pub fn idForSchemeInt(v: u8) []const u8 {
    return switch (v) {
        1 => "light",
        2 => "matrix",
        else => "dark",
    };
}
pub fn schemeIntForId(theme_id: []const u8) ?u8 {
    if (std.mem.eql(u8, theme_id, "dark")) return 0;
    if (std.mem.eql(u8, theme_id, "light")) return 1;
    if (std.mem.eql(u8, theme_id, "matrix")) return 2;
    return null;
}

// ---------------------------------------------------------------------------------------------
// Seeding — materialize the shipped themes as editable files (write-if-missing, never clobber)
// ---------------------------------------------------------------------------------------------

const seed_dark =
    \\-- veil theme: Tokyo Night (shipped default, dark)
    \\-- Every *.lua file in this folder that returns a table like this one becomes a theme
    \\-- across the whole ecosystem: desk app, web app, CLI. Copy this file to make your own —
    \\-- pick a fresh id, tweak colors, save, then re-scan (desk: click the Theme chip; web:
    \\-- reload; CLI: `veil themes`). Full authoring guide: PLUGINS.md in the repo root.
    \\return {
    \\  id      = "dark",         -- slug [a-z0-9_-], max 24 chars; this is what your pick persists as
    \\  name    = "Tokyo Night",  -- display name
    \\  dark    = true,           -- dark ground? (web derives its base scheme from this)
    \\  mono_ui = false,          -- true renders the ENTIRE UI in the mono/code font (see matrix.lua)
    \\  colors  = {               -- any subset; slots you omit fall back to the dark/light base
    \\    bg      = "#1a1b26",  -- panel ground
    \\    bg_dark = "#16161e",  -- chrome / titlebar
    \\    bg_hl   = "#1f2335",  -- hover highlight
    \\    bg_sel  = "#283457",  -- selection
    \\    fg      = "#e9edfa",  -- main text
    \\    fg_dim  = "#a9b1d6",  -- secondary text
    \\    comment = "#565f89",  -- muted text
    \\    border  = "#292e42",  -- hairlines
    \\    blue    = "#7aa2f7",  -- PRIMARY accent (buttons, active tab, focus ring)
    \\    cyan    = "#7dcfff",
    \\    green   = "#9ece6a",  -- success / online
    \\    magenta = "#bb9af7",  -- brand mark
    \\    orange  = "#ff9e64",  -- warnings
    \\    red     = "#f7768e",  -- errors / danger (keep it readable — it is the alarm color)
    \\    yellow  = "#e0af68",
    \\    teal    = "#2ac3de",
    \\  },
    \\}
    \\
;

const seed_light =
    \\-- veil theme: Light (shipped default)
    \\-- See dark.lua for the slot-by-slot commentary and PLUGINS.md for the authoring guide.
    \\return {
    \\  id      = "light",
    \\  name    = "Light",
    \\  dark    = false,
    \\  mono_ui = false,
    \\  colors  = {
    \\    bg      = "#f5f7fb",
    \\    bg_dark = "#e9edf5",
    \\    bg_hl   = "#dfe7f4",
    \\    bg_sel  = "#cfdcf3",
    \\    fg      = "#14182b",
    \\    fg_dim  = "#46557a",
    \\    comment = "#6d7a99",
    \\    border  = "#d3dbe9",
    \\    blue    = "#2f6feb",
    \\    cyan    = "#0b84a5",
    \\    green   = "#2f8f46",
    \\    magenta = "#8a3ffc",
    \\    orange  = "#c27a00",
    \\    red     = "#c93a4a",
    \\    yellow  = "#a06a00",
    \\    teal    = "#0f8a83",
    \\  },
    \\}
    \\
;

const seed_matrix =
    \\-- veil theme: Matrix (shipped, phosphor console)
    \\-- mono_ui = true is what makes this one feel like a terminal: every frontend renders its
    \\-- whole UI in the mono/code face while this theme is active. Palette rules of thumb:
    \\-- keep `red` alarming and `orange` warm even in a stylized theme — they carry meaning.
    \\return {
    \\  id      = "matrix",
    \\  name    = "Matrix",
    \\  dark    = true,
    \\  mono_ui = true,
    \\  colors  = {
    \\    bg      = "#061106",
    \\    bg_dark = "#030a03",
    \\    bg_hl   = "#0b200e",
    \\    bg_sel  = "#134020",
    \\    fg      = "#4aff7f",
    \\    fg_dim  = "#2fd465",
    \\    comment = "#1d9448",
    \\    border  = "#15421f",
    \\    blue    = "#3bff9d",
    \\    cyan    = "#00ffd0",
    \\    green   = "#00ff41",
    \\    magenta = "#bd66ff",
    \\    orange  = "#ffa028",
    \\    red     = "#ff4d4d",
    \\    yellow  = "#ffd93b",
    \\    teal    = "#00c9a0",
    \\  },
    \\}
    \\
;

/// Write the shipped theme files into `dir` when absent. Never overwrites — the workspace belongs
/// to the user once seeded.
pub fn seedDir(io: std.Io, dir: std.Io.Dir) void {
    const seeds = [_]struct { file: []const u8, body: []const u8 }{
        .{ .file = "dark.lua", .body = seed_dark },
        .{ .file = "light.lua", .body = seed_light },
        .{ .file = "matrix.lua", .body = seed_matrix },
    };
    for (seeds) |s| {
        if (dir.access(io, s.file, .{})) |_| continue else |_| {}
        dir.writeFile(io, .{ .sub_path = s.file, .data = s.body }) catch {};
    }
}

// ---------------------------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------------------------

fn parseHex(s: []const u8) ?u32 {
    var h = s;
    if (h.len > 0 and h[0] == '#') h = h[1..];
    if (h.len != 6) return null;
    var v: u32 = 0;
    for (h) |ch| {
        const d: u32 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn validId(s: []const u8) bool {
    if (s.len == 0 or s.len > ID_MAX) return false;
    for (s) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        if (!ok) return false;
    }
    return true;
}

/// Parse one theme source (the contents of a .lua file). Exposed for tests and `veil themes check`.
pub fn parseTheme(gpa: std.mem.Allocator, io: std.Io, src: []const u8, errbuf: []u8) !Theme {
    const vm = lua.Vm.init(gpa, io, .{ .mem_cap_bytes = 8 << 20, .instr_budget = 5_000_000 }) catch
        return error.VmInit;
    defer vm.deinit();
    vm.openSandboxedLibs();
    vm.runBuffer(src, "=theme", 1) catch {
        const msg = vm.lastError();
        const n = @min(msg.len, errbuf.len);
        @memcpy(errbuf[0..n], msg[0..n]);
        return error.ThemeLua;
    };
    const L = vm.L;
    if (lua.c.lua_type(L, -1) != lua.TTABLE) {
        const msg = "theme file must `return { ... }`";
        @memcpy(errbuf[0..msg.len], msg);
        return error.ThemeShape;
    }
    var t = Theme{};
    // id (required)
    if (try vm.fieldStringDup(-1, "id", gpa)) |ids| {
        defer gpa.free(ids);
        if (!validId(ids)) {
            const msg = "id must be [a-z0-9_-], 1..24 chars";
            @memcpy(errbuf[0..msg.len], msg);
            return error.ThemeShape;
        }
        t.setId(ids);
    } else {
        const msg = "missing required field: id";
        @memcpy(errbuf[0..msg.len], msg);
        return error.ThemeShape;
    }
    // name (defaults to id)
    if (try vm.fieldStringDup(-1, "name", gpa)) |nm| {
        defer gpa.free(nm);
        t.setName(nm);
    } else t.setName(t.id());
    t.dark = vm.fieldBool(-1, "dark", true);
    t.mono_ui = vm.fieldBool(-1, "mono_ui", false);
    t.builtin = schemeIntForId(t.id()) != null;
    // colors: start from the base implied by `dark`, then overlay whatever the file provides
    t.colors = if (t.dark) dark_colors else light_colors;
    const ct = lua.c.lua_getfield(L, -1, "colors");
    if (ct == lua.TTABLE) {
        for (slot_names, 0..) |slot, i| {
            if (try vm.fieldStringDup(-1, slot, gpa)) |hexs| {
                defer gpa.free(hexs);
                if (parseHex(hexs)) |v| t.colors[i] = v;
            }
        }
    }
    lua.pop(L, 1); // colors (or whatever getfield pushed)
    lua.pop(L, 1); // theme table
    return t;
}

fn upsert(set: *ThemeSet, t: Theme) void {
    for (set.items[0..set.count]) |*e| {
        if (std.mem.eql(u8, e.id(), t.id())) {
            e.* = t;
            return;
        }
    }
    if (set.count < MAX_THEMES) {
        set.items[set.count] = t;
        set.count += 1;
    }
}

/// Load the theme workspace from an OPEN dir handle: seed missing shipped files, then scan *.lua
/// (alphabetical, so cycle order is stable), builtins pinned to the front in dark/light/matrix
/// order. Never fails: worst case you get the three compiled-in themes and a report of why.
pub fn loadDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, set: *ThemeSet) void {
    set.* = .{};
    seedDir(io, dir);
    // builtins first (compiled fallbacks; files overwrite in place below)
    for (0..3) |i| upsert(set, builtinTheme(i));

    var names_buf: [MAX_THEMES * 2][64]u8 = undefined;
    var name_lens: [MAX_THEMES * 2]u8 = undefined;
    var n_files: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".lua")) continue;
        if (ent.name.len > 64) {
            set.note("{s}: filename too long, skipped", .{ent.name});
            continue;
        }
        if (n_files >= names_buf.len) break;
        @memcpy(names_buf[n_files][0..ent.name.len], ent.name);
        name_lens[n_files] = @intCast(ent.name.len);
        n_files += 1;
    }
    // insertion sort by name — the set is tiny
    var i: usize = 1;
    while (i < n_files) : (i += 1) {
        var j: usize = i;
        while (j > 0 and std.mem.lessThan(u8, names_buf[j][0..name_lens[j]], names_buf[j - 1][0..name_lens[j - 1]])) : (j -= 1) {
            std.mem.swap([64]u8, &names_buf[j], &names_buf[j - 1]);
            std.mem.swap(u8, &name_lens[j], &name_lens[j - 1]);
        }
    }
    for (0..n_files) |fi| {
        const fname = names_buf[fi][0..name_lens[fi]];
        const src = dir.readFileAlloc(io, fname, gpa, .limited(64 << 10)) catch {
            set.note("{s}: unreadable, skipped", .{fname});
            continue;
        };
        defer gpa.free(src);
        var errbuf: [256]u8 = undefined;
        @memset(&errbuf, 0);
        const t = parseTheme(gpa, io, src, &errbuf) catch {
            const msg = std.mem.sliceTo(&errbuf, 0);
            set.note("{s}: {s}", .{ fname, msg });
            continue;
        };
        if (set.count >= MAX_THEMES and set.byId(t.id()) == null) {
            set.note("{s}: theme cap ({d}) reached, skipped", .{ fname, MAX_THEMES });
            continue;
        }
        upsert(set, t);
    }
}

/// Write the compiled theme set to `<data_dir>/themes/themes.json`. The server calls this after every
/// (re)load so the DESK — a thin client sharing this machine's filesystem — can render user themes without
/// embedding Lua: it reads this JSON cache directly. Best-effort; a write failure is non-fatal (the desk
/// falls back to its compiled-in builtins).
pub fn writeCache(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, set: *const ThemeSet) void {
    // Write RELATIVE to an open themes-dir handle — NOT via cwd()+absolute sub_path, which silently
    // no-ops on Windows here (the same reason seedDir opens the dir and writes relative names into it).
    var path_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/themes", .{data_dir}) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    writeJson(set, gpa, &out) catch return;
    dir.writeFile(io, .{ .sub_path = "themes.json", .data = out.items }) catch {};
}

/// Convenience: open/create `<data_dir>/themes`, load, close.
pub fn loadWorkspace(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, set: *ThemeSet) void {
    set.* = .{};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/themes", .{data_dir}) catch {
        for (0..3) |i| upsert(set, builtinTheme(i));
        return;
    };
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        for (0..3) |i| upsert(set, builtinTheme(i));
        set.note("themes dir unavailable: {s}", .{path});
        return;
    };
    defer dir.close(io);
    loadDir(gpa, io, dir, set);
}

// ---------------------------------------------------------------------------------------------
// JSON (the /api/v1/themes payload; also reused by the CLI)
// ---------------------------------------------------------------------------------------------

/// Append the theme set as a JSON array: [{"id","name","dark","mono_ui","builtin","colors":{...}}].
pub fn writeJson(set: *const ThemeSet, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.append(gpa, '[');
    for (set.slice(), 0..) |*t, ti| {
        if (ti > 0) try out.append(gpa, ',');
        try out.print(gpa, "{{\"id\":\"{s}\",\"name\":\"", .{t.id()});
        for (t.name()) |ch| {
            if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
            if (ch >= 0x20) try out.append(gpa, ch);
        }
        try out.print(gpa, "\",\"dark\":{},\"mono_ui\":{},\"builtin\":{},\"colors\":{{", .{ t.dark, t.mono_ui, t.builtin });
        for (slot_names, 0..) |slot, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "\"{s}\":\"#{x:0>6}\"", .{ slot, t.colors[i] });
        }
        try out.appendSlice(gpa, "}}");
    }
    try out.append(gpa, ']');
}

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

test "parseTheme: full custom theme parses; hex + flags land" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var errbuf: [256]u8 = undefined;
    const t = try parseTheme(std.testing.allocator, io,
        \\return { id = "ember", name = "Ember", dark = true, mono_ui = true,
        \\  colors = { bg = "#201510", fg = "#ffcc99", red = "ff2200" } }
    , &errbuf);
    try std.testing.expectEqualStrings("ember", t.id());
    try std.testing.expectEqualStrings("Ember", t.name());
    try std.testing.expect(t.dark and t.mono_ui and !t.builtin);
    try std.testing.expectEqual(@as(u32, 0x201510), t.colors[0]);
    try std.testing.expectEqual(@as(u32, 0xffcc99), t.colors[4]);
    try std.testing.expectEqual(@as(u32, 0xff2200), t.colors[13]); // '#' optional
    // unspecified slot fell back to the dark base
    try std.testing.expectEqual(dark_colors[8], t.colors[8]);
}

test "parseTheme: rejects bad ids and non-table returns" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var errbuf: [256]u8 = undefined;
    try std.testing.expectError(error.ThemeShape, parseTheme(std.testing.allocator, io, "return { id = \"Bad Id!\" }", &errbuf));
    try std.testing.expectError(error.ThemeShape, parseTheme(std.testing.allocator, io, "return 42", &errbuf));
    try std.testing.expectError(error.ThemeShape, parseTheme(std.testing.allocator, io, "return { name = \"no id\" }", &errbuf));
    try std.testing.expectError(error.ThemeLua, parseTheme(std.testing.allocator, io, "this is not lua", &errbuf));
}

test "loadDir: seeds builtins, custom file joins, file overrides builtin, junk reported" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var set: ThemeSet = undefined;
    loadDir(std.testing.allocator, io, tmp.dir, &set);
    // seeded trio present, pinned order
    try std.testing.expectEqual(@as(usize, 3), set.count);
    try std.testing.expectEqualStrings("dark", set.items[0].id());
    try std.testing.expectEqualStrings("light", set.items[1].id());
    try std.testing.expectEqualStrings("matrix", set.items[2].id());
    try std.testing.expect(set.items[2].mono_ui);
    // seed files actually exist now
    try tmp.dir.access(io, "matrix.lua", .{});
    // add a custom theme + a broken file + a builtin override
    try tmp.dir.writeFile(io, .{ .sub_path = "zebra.lua", .data = "return { id = \"zebra\", name = \"Zebra\", dark = false }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.lua", .data = "retur n {" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dark.lua", .data = "return { id = \"dark\", name = \"Darker\", colors = { bg = \"#000000\" } }" });
    loadDir(std.testing.allocator, io, tmp.dir, &set);
    try std.testing.expectEqual(@as(usize, 4), set.count);
    // override kept position 0 but took the file's values; still flagged builtin
    try std.testing.expectEqualStrings("Darker", set.items[0].name());
    try std.testing.expectEqual(@as(u32, 0), set.items[0].colors[0]);
    try std.testing.expect(set.items[0].builtin);
    const z = set.byId("zebra").?;
    try std.testing.expect(!z.dark and !z.builtin);
    try std.testing.expectEqual(light_colors[4], z.colors[4]); // light base fill
    try std.testing.expect(std.mem.indexOf(u8, set.report(), "broken.lua") != null);
}

test "writeJson emits an array with hex colors" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var set: ThemeSet = undefined;
    loadDir(std.testing.allocator, io, tmp.dir, &set);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try writeJson(&set, std.testing.allocator, &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "[{\"id\":\"dark\""));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"matrix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "#00ff41") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
}

test "legacy scheme int mapping is stable" {
    try std.testing.expectEqualStrings("dark", idForSchemeInt(0));
    try std.testing.expectEqualStrings("light", idForSchemeInt(1));
    try std.testing.expectEqualStrings("matrix", idForSchemeInt(2));
    try std.testing.expectEqual(@as(u8, 2), schemeIntForId("matrix").?);
    try std.testing.expect(schemeIntForId("zebra") == null);
}
