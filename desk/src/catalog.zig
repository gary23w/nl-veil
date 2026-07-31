//! catalog.zig — the desk's view of the model catalog + the deploy option sets.
//!
//! The provider/model list is NO LONGER hand-written here: it comes from `modelcfg` (the shared module
//! that comptime-parses the repo-root models.yaml, the SAME source the server reads), so every desk menu
//! — chat Settings, Swarm deploy, Tasks model override — and the server stay in lockstep. Edit
//! models.yaml, rebuild, everything updates. This file keeps only the desk-specific pieces: resolveBase()
//! (the {account} substitution the desk does before sending) and the deploy option sets (styles / stacks
//! / modes / minutes), which are workflow knobs, not models.

const std = @import("std");
const log = @import("log.zig");
const modelcfg = @import("modelcfg");

pub const Model = modelcfg.Model;
pub const Provider = modelcfg.Provider;

/// Model capacity sensing (params/ctx/tier from yaml metadata or the model id) — the desk keys its
/// prompt variant + per-section budgets off this; see chat.zig budgetFor.
pub const Tier = modelcfg.Tier;
pub const ModelSense = modelcfg.ModelSense;
pub const senseModel = modelcfg.senseModel;

/// THE provider list — a comptime slice from models.yaml. Array-style access (`providers[i]`,
/// `providers.len`, `for (providers)`) works exactly as the old in-file array did.
pub const providers = modelcfg.providers;

/// Model defaults (local + Cloudflare) sourced from models.yaml, for the "no model chosen" fallbacks.
pub const defaults = modelcfg.defaults;

/// Resolve a provider's base_url. If the template carries the "{account}" placeholder (Cloudflare Workers AI),
/// substitute the account id into `out` and return that slice; with no account id, return the "cloudflare"
/// sentinel so the server falls back to its own included/env credentials. Non-templated URLs pass through.
pub fn resolveBase(p: *const Provider, account: []const u8, out: []u8) []const u8 {
    log.trace("catalog.resolveBase provider={s} has_account={}", .{ p.key, account.len > 0 });
    const marker = "{account}";
    const at = std.mem.indexOf(u8, p.base_url, marker) orelse return p.base_url;
    const acct = std.mem.trim(u8, account, " \t\r\n");
    if (acct.len == 0) return "cloudflare"; // no account → let the server use its configured Workers AI creds
    const pre = p.base_url[0..at];
    const post = p.base_url[at + marker.len ..];
    if (pre.len + acct.len + post.len > out.len) return "cloudflare"; // won't fit → safe fallback
    var w: usize = 0;
    @memcpy(out[w .. w + pre.len], pre);
    w += pre.len;
    @memcpy(out[w .. w + acct.len], acct);
    w += acct.len;
    @memcpy(out[w .. w + post.len], post);
    w += post.len;
    return out[0..w];
}

pub const styles = [_][]const u8{ "auto", "build", "build_use", "investigate", "debate" };
pub const stacks = [_][]const u8{ "general", "static", "node" };
// "cast" is the fast scatter-gather type: the lead decomposes the goal, each mind runs ONE moment on its
// slice, then it stops (~1-2 min) and the result is synthesized — vs "continuous" which loops for the whole
// budget. Deploy it from here just like any other swarm, or from the chat.
pub const modes = [_][]const u8{ "continuous", "checkpoint", "refine", "cast" };
pub const minutes = [_]u32{ 0, 5, 15, 30, 60 };
pub const minutes_lbl = [_][]const u8{ "until stopped", "5", "15", "30", "60" };

// ---- tests ---------------------------------------------------------------------------------------------
//
// resolveBase's three headline cases (substitution, the "cloudflare" sentinel, pass-through) are already
// pinned in chat.zig, "resolveBase substitutes the Cloudflare {account}, falls back to the sentinel, and
// passes others through". What follows covers what that test cannot see: the undersized-buffer branch, the
// invariant that has to hold over the WHOLE shipped catalog, and the deploy option sets the UI indexes.

/// The size EVERY resolveBase call site declares for its scratch (main.zig `basebuf` / `acct_scratch`,
/// chat.zig `acct` / `acct_scratch` — all `[256]u8`). Not a knob: a base that outgrows it silently becomes
/// the sentinel instead of the endpoint the user configured, so the size is part of the contract.
const CALLSITE_SCRATCH = 256;

/// A hand-built templated provider. The only catalog entry that ever carried "{account}" (workers-ai) is
/// commented out of models.yaml, so the substitution path has to be driven through a synthetic Provider —
/// resolveBase takes a `*const Provider` precisely so it can be.
fn cfTemplateProvider() Provider {
    return .{
        .key = "workers-ai",
        .label = "Cloudflare Workers AI",
        .base_url = "https://api.cloudflare.com/client/v4/accounts/{account}/ai/v1",
        .needs_key = true,
        .needs_account = true,
        .keyless = true,
    };
}

test "resolveBase degrades to the sentinel rather than hand back a half-written endpoint" {
    const cf = cfTemplateProvider();
    const acct = "abc123";
    const want = "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1";
    // room for exactly the resolved URL and not one byte more: the fit check is `>`, so this must resolve
    var exact: [want.len]u8 = undefined;
    try std.testing.expectEqualStrings(want, resolveBase(&cf, acct, &exact));
    // one byte short. A truncated base is not a harmless string — it is a live endpoint the desk would send
    // to the server ("…/accounts/abc123/ai/v" resolves to nothing), so the only safe answer is the sentinel
    // that tells the server to use its own configured Workers AI credentials.
    var short: [want.len - 1]u8 = undefined;
    try std.testing.expectEqualStrings("cloudflare", resolveBase(&cf, acct, &short));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("cloudflare", resolveBase(&cf, acct, &tiny));
    // an account id long enough to overflow the scratch is the same story, not a buffer overrun
    var normal: [CALLSITE_SCRATCH]u8 = undefined;
    try std.testing.expectEqualStrings("cloudflare", resolveBase(&cf, "a" ** 300, &normal));
}

test "no provider the catalog ships can resolve to a base that still carries the placeholder" {
    var out: [CALLSITE_SCRATCH]u8 = undefined;
    for (providers) |p| {
        for ([_][]const u8{ "", "   \t\r\n", "abc123", "0123456789abcdef0123456789abcdef" }) |acct| {
            const b = resolveBase(&p, acct, &out);
            // an unsubstituted "{account}" would be sent verbatim as the endpoint host path
            try std.testing.expect(std.mem.indexOf(u8, b, "{account}") == null);
            if (std.mem.indexOf(u8, p.base_url, "{account}") == null) {
                // an untemplated base is handed back BY REFERENCE (static yaml bytes), not copied into the
                // scratch. Call sites keep the slice after their stack scratch goes out of scope
                // (main.zig 5348, chat.zig 3519), so the aliasing is load-bearing, not incidental.
                try std.testing.expectEqual(p.base_url.ptr, b.ptr);
                try std.testing.expectEqualStrings(p.base_url, b);
            }
        }
    }
}

test "the whole shipped catalog fits the 256-byte scratch every call site declares" {
    var out: [CALLSITE_SCRATCH]u8 = undefined;
    for (providers) |p| {
        // mock ships an empty base on purpose, and builtin ships the "builtin" SENTINEL the server
        // swaps for its live engine endpoint (worker/builtin.zig — the desk passes it through
        // verbatim, which is exactly why it must NOT look like a URL); everything else is an
        // absolute URL the desk hands the server.
        try std.testing.expect(p.base_url.len <= CALLSITE_SCRATCH);
        if (p.base_url.len > 0 and !std.mem.eql(u8, p.base_url, "builtin"))
            try std.testing.expect(std.mem.startsWith(u8, p.base_url, "http"));
        _ = resolveBase(&p, "", &out);
    }
    // and a resolved template with a real 32-hex Cloudflare account id still fits — if it ever stops
    // fitting the desk does not error, it quietly deploys against the wrong credentials
    const cf = cfTemplateProvider();
    const resolved = resolveBase(&cf, "0123456789abcdef0123456789abcdef", &out);
    try std.testing.expect(!std.mem.eql(u8, resolved, "cloudflare"));
    try std.testing.expect(resolved.len <= CALLSITE_SCRATCH);
}

test "the runtime dropdown indexes two arrays with one index, and every label means its value" {
    // main.zig renders minutes_lbl[d_minutes] and sends minutes[d_minutes]: ONE index, TWO arrays, so a
    // length mismatch is an out-of-bounds read the moment someone opens the dropdown.
    try std.testing.expectEqual(minutes.len, minutes_lbl.len);
    // row 0 is the sentinel — 0 minutes means "run until stopped", and the label has to say so
    try std.testing.expectEqual(@as(u32, 0), minutes[0]);
    try std.testing.expectEqualStrings("until stopped", minutes_lbl[0]);
    // every other label parses back to its own value: the label is the number, not decoration next to it
    for (minutes[1..], minutes_lbl[1..]) |m, lbl| {
        try std.testing.expect(m > 0);
        try std.testing.expectEqual(m, try std.fmt.parseInt(u32, lbl, 10));
    }
    // main.zig ships `d_minutes: usize = 3` as the deploy form's default — it has to address a real row
    try std.testing.expect(minutes.len > 3);
}

test "a deploy option set maps one index to one value — no blanks, no duplicates" {
    inline for (.{ &styles, &stacks, &modes }) |set| {
        try std.testing.expect(set.len > 0);
        for (set, 0..) |a, i| {
            try std.testing.expect(a.len > 0); // a blank row is an unlabelled dropdown entry
            // a duplicate makes two indices mean the same deploy, so the selection can never round-trip
            for (set[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    // index 0 is what the deploy form ships with (d_style / d_stack / d_mode all default to 0)
    try std.testing.expectEqualStrings("auto", styles[0]);
    try std.testing.expectEqualStrings("general", stacks[0]);
    try std.testing.expectEqualStrings("continuous", modes[0]);
    // the two modes the CHAT deploys by name (chat.zig: `if (spec.long) "continuous" else "cast"`) must
    // both exist here — the desk dropdown and the chat's cast path feed the same server field.
    var saw_cast = false;
    var saw_continuous = false;
    for (modes) |m| {
        if (std.mem.eql(u8, m, "cast")) saw_cast = true;
        if (std.mem.eql(u8, m, "continuous")) saw_continuous = true;
    }
    try std.testing.expect(saw_cast and saw_continuous);
}

test "the desk reads the SAME catalog the server does — a re-export, not a second list" {
    // The import sits INSIDE the test so nothing outside the test binary is coupled. This file's entire
    // reason to exist is that models.yaml is the one source; a hand-written list creeping back in here (the
    // shape this file used to have) has to fail the build rather than the next deploy.
    const mc = @import("modelcfg");
    comptime std.debug.assert(Model == mc.Model and Provider == mc.Provider);
    comptime std.debug.assert(Tier == mc.Tier and ModelSense == mc.ModelSense);
    try std.testing.expectEqual(mc.providers.ptr, providers.ptr); // the same bytes, not a copy of them
    try std.testing.expectEqual(mc.providers.len, providers.len);
    try std.testing.expectEqualStrings(mc.defaults.local_model, defaults.local_model);
    try std.testing.expectEqualStrings(mc.defaults.cf_model, defaults.cf_model);
    // and the capacity read the desk keys its prompt variant + section budgets off is the server's read
    for ([_][]const u8{ "gpt-oss:20b", "claude-opus-4-8", "gpt-4.1-mini", defaults.cf_model }) |id| {
        const a = senseModel(id, false);
        const b = mc.senseModel(id, false);
        try std.testing.expectEqual(b.tier, a.tier);
        try std.testing.expectEqual(b.ctx_k, a.ctx_k);
        try std.testing.expectEqual(b.params_b, a.params_b);
    }
}
