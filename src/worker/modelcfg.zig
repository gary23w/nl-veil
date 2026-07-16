//! modelcfg.zig — the ONE model catalog, parsed at COMPTIME from the build-embedded models.yaml.
//!
//! Both binaries consume this file: the server imports it directly (the yaml rides the root module as an
//! anonymous import, like the embedded web assets), and the desk's catalog.zig re-exports it (its build
//! registers its own copy of the yaml). Every model menu — chat Settings, Swarm deploy, Tasks model
//! override — and the server's provider logic (keyless deploys, local detection, default models) reads
//! the SAME list. Edit models.yaml, rebuild, and the whole app updates coherently.
//!
//! The parse runs at COMPTIME, so `providers` is a real comptime array (array indexing, `.len`, `for`
//! all work exactly as the old hand-written catalog did — zero call-site churn) and every string is a
//! slice of the embedded bytes (static lifetime, no allocation, no init step). The parser accepts the
//! deliberate YAML SUBSET documented at the top of models.yaml (two-space indents, `- ` list items with
//! an inline first field, bare or "double-quoted" scalars, true/false booleans, full-line comments).

const std = @import("std");

const RAW: []const u8 = @embedFile("models.yaml");

pub const Model = struct { id: []const u8, label: []const u8 };

pub const Provider = struct {
    key: []const u8,
    label: []const u8,
    base_url: []const u8, // may carry the "{account}" placeholder (Cloudflare) — the desk resolves it
    needs_key: bool = false,
    needs_account: bool = false,
    keyless: bool = false, // server accepts a deploy without a key (local endpoint / server-side creds)
    local: bool = false, // runs on the user's machine
    models: []const Model = &.{},
};

pub const Defaults = struct {
    local_model: []const u8 = "gpt-oss:20b",
    cf_model: []const u8 = "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
};

/// The catalog, parsed once at compile time. A generous eval-branch quota covers the line scan.
pub const providers: []const Provider = parsed.providers;
pub const defaults: Defaults = parsed.defaults;

const Parsed = struct { providers: []const Provider, defaults: Defaults };

const parsed: Parsed = blk: {
    // Generous: the parse re-scans the embedded file per provider (comptime splitScalar is O(n) per line),
    // so a ~200-line catalog costs a few million branches. Comptime-only — no runtime cost.
    @setEvalBranchQuota(20_000_000);
    break :blk parse();
};

/// May this provider deploy WITHOUT an api key? (local endpoints, or server-side credential fallback)
pub fn isKeyless(key: []const u8) bool {
    for (providers) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.keyless;
    }
    return false;
}

/// Does this provider run on the user's own machine?
pub fn isLocal(key: []const u8) bool {
    for (providers) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.local;
    }
    return false;
}

// ---- the comptime subset parser ------------------------------------------------------------------------

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn valueOf(rest: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return "";
    var v = std.mem.trim(u8, rest[colon + 1 ..], " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
    return v;
}

fn keyOf(rest: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return rest;
    return std.mem.trim(u8, rest[0..colon], " \t");
}

/// Count how many `- ` items sit at `at_indent` inside the `providers:`/`models:` section that begins at
/// `from` — used to size the comptime arrays before filling them.
fn countItems(raw: []const u8, comptime section: []const u8) usize {
    var n: usize = 0;
    var in = false;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |lr| {
        const line = std.mem.trimEnd(u8, lr, " \r");
        const t = std.mem.trimStart(u8, line, " ");
        if (t.len == 0 or t[0] == '#') continue;
        if (indentOf(line) == 0) {
            in = std.mem.eql(u8, keyOf(t), section);
            continue;
        }
        if (in and indentOf(line) == 2 and std.mem.startsWith(u8, t, "- ")) n += 1;
    }
    return n;
}

fn parse() Parsed {
    const nprov = countItems(RAW, "providers");
    var provs: [nprov]Provider = undefined;
    var defs = Defaults{};
    var pi: usize = 0;

    // pass 1: providers + their flat fields + defaults
    var section: enum { none, defaults, providers } = .none;
    var it = std.mem.splitScalar(u8, RAW, '\n');
    while (it.next()) |lr| {
        const line = std.mem.trimEnd(u8, lr, " \r");
        const t = std.mem.trimStart(u8, line, " ");
        if (t.len == 0 or t[0] == '#') continue;
        const ind = indentOf(line);
        if (ind == 0) {
            const k = keyOf(t);
            section = if (std.mem.eql(u8, k, "defaults")) .defaults else if (std.mem.eql(u8, k, "providers")) .providers else .none;
            continue;
        }
        switch (section) {
            .defaults => if (ind == 2) {
                const k = keyOf(t);
                if (std.mem.eql(u8, k, "local_model")) defs.local_model = valueOf(t);
                if (std.mem.eql(u8, k, "cf_model")) defs.cf_model = valueOf(t);
            },
            .providers => {
                if (ind == 2 and std.mem.startsWith(u8, t, "- ")) {
                    provs[pi] = .{ .key = valueOf(t[2..]), .label = "", .base_url = "", .models = &.{} };
                    pi += 1;
                } else if (pi > 0 and ind == 4) {
                    const k = keyOf(t);
                    const v = valueOf(t);
                    const p = &provs[pi - 1];
                    if (std.mem.eql(u8, k, "label")) {
                        p.label = v;
                    } else if (std.mem.eql(u8, k, "base")) {
                        p.base_url = v;
                    } else if (std.mem.eql(u8, k, "needs_key")) {
                        p.needs_key = std.mem.eql(u8, v, "true");
                    } else if (std.mem.eql(u8, k, "needs_account")) {
                        p.needs_account = std.mem.eql(u8, v, "true");
                    } else if (std.mem.eql(u8, k, "keyless")) {
                        p.keyless = std.mem.eql(u8, v, "true");
                    } else if (std.mem.eql(u8, k, "local")) {
                        p.local = std.mem.eql(u8, v, "true");
                    }
                }
            },
            .none => {},
        }
    }

    // pass 2: each provider's model list (comptime array per provider → static const slice)
    for (0..nprov) |idx| provs[idx].models = parseModels(RAW, provs[idx].key);

    const frozen = provs;
    return .{ .providers = &frozen, .defaults = defs };
}

/// The models under the provider whose `- key: <key>` line we match — returned as a comptime slice.
fn parseModels(raw: []const u8, comptime want_key: []const u8) []const Model {
    // size first
    var count: usize = 0;
    {
        var in_prov = false;
        var in_models = false;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |lr| {
            const line = std.mem.trimEnd(u8, lr, " \r");
            const t = std.mem.trimStart(u8, line, " ");
            if (t.len == 0 or t[0] == '#') continue;
            const ind = indentOf(line);
            if (ind == 2 and std.mem.startsWith(u8, t, "- ")) {
                in_prov = std.mem.eql(u8, valueOf(t[2..]), want_key);
                in_models = false;
                continue;
            }
            if (!in_prov) continue;
            if (ind == 4 and std.mem.eql(u8, keyOf(t), "models")) in_models = true;
            if (in_models and ind == 6 and std.mem.startsWith(u8, t, "- ")) count += 1;
        }
    }
    var ms: [count]Model = undefined;
    var mi: usize = 0;
    var in_prov = false;
    var in_models = false;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |lr| {
        const line = std.mem.trimEnd(u8, lr, " \r");
        const t = std.mem.trimStart(u8, line, " ");
        if (t.len == 0 or t[0] == '#') continue;
        const ind = indentOf(line);
        if (ind == 2 and std.mem.startsWith(u8, t, "- ")) {
            in_prov = std.mem.eql(u8, valueOf(t[2..]), want_key);
            in_models = false;
            continue;
        }
        if (!in_prov) continue;
        if (ind == 4) in_models = std.mem.eql(u8, keyOf(t), "models");
        if (in_models and ind == 6 and std.mem.startsWith(u8, t, "- ")) {
            ms[mi] = .{ .id = valueOf(t[2..]), .label = "" };
            mi += 1;
        } else if (in_models and ind == 8 and mi > 0 and std.mem.eql(u8, keyOf(t), "label")) {
            ms[mi - 1].label = valueOf(t);
        }
    }
    for (0..count) |i| {
        if (ms[i].label.len == 0) ms[i].label = ms[i].id; // menus never show a blank
    }
    const frozen = ms;
    return &frozen;
}

// ---- tests: the EMBEDDED catalog itself is the fixture — CI fails on a bad edit -------------------------

test "models.yaml parses: provider order pins the desk's persisted dropdown indices" {
    try std.testing.expect(providers.len >= 9);
    // the legacy indices the desk persisted — order is a compatibility contract (append-only)
    const expect = [_][]const u8{ "anthropic", "openai", "ollama", "workers-ai", "groq", "deepseek", "google", "mock", "huggingface" };
    for (expect, 0..) |k, i| try std.testing.expectEqualStrings(k, providers[i].key);
}

test "models.yaml parses: fields, flags, models, quoted scalars, defaults" {
    try std.testing.expectEqualStrings("Anthropic (Claude)", providers[0].label);
    try std.testing.expect(providers[0].needs_key and !providers[0].keyless);
    try std.testing.expect(providers[0].models.len >= 4);
    try std.testing.expectEqualStrings("claude-opus-4-8", providers[0].models[0].id);
    try std.testing.expectEqualStrings("Claude Opus 4.8", providers[0].models[0].label);
    // local/keyless flags drive the server's deploy logic
    try std.testing.expect(isKeyless("ollama") and isLocal("ollama"));
    try std.testing.expect(isKeyless("workers-ai") and !isLocal("workers-ai"));
    try std.testing.expect(isKeyless("mock") and !isKeyless("anthropic") and !isKeyless("nope"));
    // quoted scalars survive (@cf model ids) and the {account} template survives
    try std.testing.expectEqualStrings("@cf/meta/llama-3.3-70b-instruct-fp8-fast", providers[3].models[0].id);
    try std.testing.expect(std.mem.indexOf(u8, providers[3].base_url, "{account}") != null and providers[3].needs_account);
    // defaults
    try std.testing.expectEqualStrings("gpt-oss:20b", defaults.local_model);
    try std.testing.expectEqualStrings("@cf/meta/llama-3.3-70b-instruct-fp8-fast", defaults.cf_model);
}
