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

pub const Model = struct {
    id: []const u8,
    label: []const u8,
    // Optional CAPACITY metadata (yaml `params_b:` / `ctx_k:` / `tier:`). 0 / null = unspecified — the
    // catalog never guesses; senseModel() infers what the yaml doesn't state from the model id itself.
    params_b: u32 = 0, // parameter count in BILLIONS (rounded)
    ctx_k: u32 = 0, // context window in K tokens
    tier_ovr: ?Tier = null, // explicit tier pin — wins over every inference (e.g. a rotating free-model router)
};

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

// ---- model capacity sensing ----------------------------------------------------------------------------
//
// Different-sized models need different-sized prompts: an 8B/20B local model drowns in the same ~13KB
// system doctrine a trillion-parameter frontier model digests without noticing, and a small context
// window can't hold the full history + memory injection either. senseModel() is the ONE shared read of
// "how big is this model": both binaries key their prompt VARIANT and per-section byte budgets off the
// returned tier. Deliberately signal-driven, never a per-model hardcode: the yaml may state capacity
// (`params_b:` / `ctx_k:` / `tier:`), otherwise it is inferred from the model id itself (models are
// conventionally NAMED by size — "8b", "20b", "70b", "128k"), the provider's `local` flag, and the
// light-variant naming convention ("mini"/"nano"/"flash"/…). A live probe (Ollama /api/show) is even
// better ground truth — callers that have one feed it in on top (see run.zig's budget-coherence block).

/// Capability tier — picks the prompt variant + scales the per-section context budgets.
/// small ≈ ≤24B params (or a ≤15k window): compact doctrine, lean injections.
/// mid   ≈ 25-199B (or ≤47k window): full doctrine, moderated injections.
/// large ≈ ≥200B / frontier-named hosted models: full doctrine, full budgets.
pub const Tier = enum(u8) {
    small = 0,
    mid = 1,
    large = 2,
    pub fn label(t: Tier) []const u8 {
        return switch (t) {
            .small => "small",
            .mid => "mid",
            .large => "large",
        };
    }
};

pub const ModelSense = struct {
    params_b: u32 = 0, // billions, rounded; 0 = unknown
    ctx_k: u32 = 0, // context window in K tokens; senseModel always fills it (tier default when unknown)
    tier: Tier = .large,
};

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Parameter count in TENTHS of a billion parsed from the id ("8b"→80, "1.5b"→15, "8x7b"→560,
/// "135m"→1), 0 = the name doesn't say. Takes the LARGEST match so MoE ids like "235b-a22b" read as
/// total params, not active. A digit run counts only when 'b' (billions) or 'm' (millions) directly
/// follows it and the next char is a non-alphanumeric boundary — "fp8-fast" and "v1" never match.
fn paramsTenthsFromId(id: []const u8) u64 {
    var best: u64 = 0;
    var prev_run: u64 = 0; // last completed digit run, for the "8x7b" MoE form
    var prev_sep: u8 = 0; // the single separator between that run and this one
    var i: usize = 0;
    while (i < id.len) {
        if (id[i] < '0' or id[i] > '9') {
            i += 1;
            continue;
        }
        var v: u64 = 0;
        while (i < id.len and id[i] >= '0' and id[i] <= '9') : (i += 1) v = @min(v * 10 + (id[i] - '0'), 1_000_000);
        var tenths: u64 = v * 10;
        // one decimal digit ("1.5b", "0.5b") — folded in, further digits ignored
        if (i + 1 < id.len and id[i] == '.' and id[i + 1] >= '0' and id[i + 1] <= '9') {
            var j = i + 1;
            tenths += id[j] - '0';
            while (j < id.len and id[j] >= '0' and id[j] <= '9') : (j += 1) {}
            // a decimal run continues to the suffix check below only when it ends the number
            if (j < id.len and lower(id[j]) == 'b' and boundaryAfter(id, j + 1)) {
                best = @max(best, tenths);
                prev_run = 0;
                i = j + 1;
                continue;
            }
            i = j;
            prev_run = 0;
            continue;
        }
        if (i < id.len and lower(id[i]) == 'b' and boundaryAfter(id, i + 1)) {
            var cand = tenths;
            if (prev_sep == 'x' and prev_run > 0) cand = prev_run * tenths / 10; // "8x7b" → 8*7
            best = @max(best, @min(cand, 1_000_000_0));
            prev_run = 0;
            i += 1;
            continue;
        }
        if (i < id.len and lower(id[i]) == 'm' and boundaryAfter(id, i + 1) and v < 1000) {
            best = @max(best, 1); // sub-billion ("135m") — round up to a token 0.1B so it reads as KNOWN-small
            prev_run = 0;
            i += 1;
            continue;
        }
        prev_run = tenths;
        prev_sep = if (i < id.len) lower(id[i]) else 0;
    }
    return best;
}

/// Context window in K tokens parsed from the id ("8k"/"32k"/"128k"), 0 = the name doesn't say.
fn ctxKFromId(id: []const u8) u32 {
    var best: u32 = 0;
    var i: usize = 0;
    while (i < id.len) {
        if (id[i] < '0' or id[i] > '9') {
            i += 1;
            continue;
        }
        var v: u32 = 0;
        while (i < id.len and id[i] >= '0' and id[i] <= '9') : (i += 1) v = @min(v * 10 + (id[i] - '0'), 100_000);
        if (i < id.len and lower(id[i]) == 'k' and boundaryAfter(id, i + 1)) {
            best = @max(best, @min(v, 10_000));
            i += 1;
        }
    }
    return best;
}

fn boundaryAfter(id: []const u8, at: usize) bool {
    if (at >= id.len) return true;
    const c = lower(id[at]);
    return !((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
}

/// Hosted models named as the LIGHT variant of a family ("gpt-4.1-mini", "gemini-…-flash", "glm-4.5-air"):
/// distilled but competent — mid, not small. The marker must be a whole '-'/'_'/'.'/':'-bounded segment so
/// "minimax" never reads as "mini".
fn hasLightMarker(id: []const u8) bool {
    const markers = [_][]const u8{ "mini", "nano", "flash", "lite", "tiny", "micro", "air", "small" };
    for (markers) |m| {
        var start: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(id, start, m)) |at| {
            const pre_ok = at == 0 or !std.ascii.isAlphanumeric(id[at - 1]);
            const post_ok = boundaryAfter(id, at + m.len);
            if (pre_ok and post_ok) return true;
            start = at + 1;
        }
    }
    return false;
}

fn tierFromParamsTenths(tenths: u64) Tier {
    if (tenths <= 24 * 10) return .small;
    if (tenths <= 199 * 10) return .mid;
    return .large;
}

fn tierFromCtxK(ctx_k: u32) Tier {
    if (ctx_k <= 15) return .small;
    if (ctx_k <= 47) return .mid;
    return .large;
}

/// The ONE capacity read: yaml-stated metadata when the catalog has it, name-derived otherwise, provider
/// `local` flag folded in. `local_hint` covers models OUTSIDE the catalog (a custom localhost endpoint).
/// The returned ctx_k is always non-zero (tier default when nothing states it): small→8, mid→32, large→128.
pub fn senseModel(model_id: []const u8, local_hint: bool) ModelSense {
    var params_tenths: u64 = 0;
    var ctx_k: u32 = 0;
    var tier_ovr: ?Tier = null;
    var local = local_hint;
    outer: for (providers) |p| {
        for (p.models) |m| {
            if (!std.mem.eql(u8, m.id, model_id)) continue;
            params_tenths = @as(u64, m.params_b) * 10;
            ctx_k = m.ctx_k;
            tier_ovr = m.tier_ovr;
            if (p.local) local = true;
            break :outer;
        }
    }
    if (params_tenths == 0) params_tenths = paramsTenthsFromId(model_id);
    if (ctx_k == 0) ctx_k = ctxKFromId(model_id);
    const ptier: Tier = if (params_tenths > 0)
        tierFromParamsTenths(params_tenths)
    else if (local)
        .small // an unnamed local model on consumer hardware: assume small, never drown it
    else if (hasLightMarker(model_id))
        .mid
    else
        .large; // hosted frontier models hide their size behind brand names
    var tier: Tier = if (tier_ovr) |t| t else ptier;
    // a small window caps the tier regardless of params — the budgets must FIT the window
    if (tier_ovr == null and ctx_k > 0 and @intFromEnum(tierFromCtxK(ctx_k)) < @intFromEnum(tier))
        tier = tierFromCtxK(ctx_k);
    if (ctx_k == 0) ctx_k = switch (tier) {
        .small => 8,
        .mid => 32,
        .large => 128,
    };
    return .{
        .params_b = @intCast((params_tenths + 5) / 10),
        .ctx_k = ctx_k,
        .tier = tier,
    };
}

// ---- the comptime subset parser ------------------------------------------------------------------------

/// Comptime-safe decimal parse (yaml capacity fields); bad/empty input reads as 0 (= unspecified).
fn atoi(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        v = @min(v * 10 + (c - '0'), 1_000_000);
    }
    return v;
}

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
        } else if (in_models and ind == 8 and mi > 0) {
            const k = keyOf(t);
            const v = valueOf(t);
            if (std.mem.eql(u8, k, "label")) {
                ms[mi - 1].label = v;
            } else if (std.mem.eql(u8, k, "params_b")) {
                ms[mi - 1].params_b = atoi(v);
            } else if (std.mem.eql(u8, k, "ctx_k")) {
                ms[mi - 1].ctx_k = atoi(v);
            } else if (std.mem.eql(u8, k, "tier")) {
                ms[mi - 1].tier_ovr = if (std.mem.eql(u8, v, "small")) .small else if (std.mem.eql(u8, v, "mid")) .mid else if (std.mem.eql(u8, v, "large")) .large else null;
            }
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
    try std.testing.expect(providers.len >= 13);
    // the persisted dropdown indices — order is a compatibility contract (append-only)
    const expect = [_][]const u8{ "anthropic", "openai", "ollama", "workers-ai", "groq", "deepseek", "google", "mock", "huggingface", "zai", "tokengo", "openrouter", "moonshot" };
    for (expect, 0..) |k, i| try std.testing.expectEqualStrings(k, providers[i].key);
}

test "moonshot (Kimi) provider: first-party API, kimi-k3 flagship first, OpenAI-compatible BYOK" {
    const p = for (providers) |pr| {
        if (std.mem.eql(u8, pr.key, "moonshot")) break pr;
    } else unreachable;
    try std.testing.expectEqualStrings("https://api.moonshot.ai/v1", p.base_url);
    try std.testing.expect(p.needs_key and !p.keyless and !p.local and !p.needs_account);
    try std.testing.expectEqualStrings("kimi-k3", p.models[0].id); // flagship = the provider's default model
    try std.testing.expectEqualStrings("Kimi K3 (flagship, 1M ctx)", p.models[0].label);
    // exactly the four ids the live API serves (GET /v1/models, 2026-07-17) — the catalog once listed the
    // legacy moonshot-v1-* line and kimi-k2.5, which the API rejects with "Not found the model or Permission
    // denied"; a catalog entry that can't complete a request is worse than none.
    try std.testing.expectEqual(@as(usize, 4), p.models.len);
    // a dotted id survives the bare-scalar parse (no quoting needed)
    try std.testing.expectEqualStrings("kimi-k2.7-code", p.models[1].id);
    try std.testing.expectEqualStrings("kimi-k2.7-code-highspeed", p.models[2].id);
    try std.testing.expectEqualStrings("kimi-k2.6", p.models[3].id);
}

test "senseModel: param count sensed from the id — 8b/20b small, 70b/120b mid, frontier large" {
    // the user's own ladder: 8b / 20b / 120b vs trillion-param frontier models
    try std.testing.expectEqual(Tier.small, senseModel("llama3.1:8b", false).tier);
    try std.testing.expectEqual(Tier.small, senseModel("gpt-oss:20b", false).tier);
    try std.testing.expectEqual(@as(u32, 20), senseModel("gpt-oss:20b", false).params_b);
    try std.testing.expectEqual(Tier.mid, senseModel("openai/gpt-oss-120b", false).tier);
    try std.testing.expectEqual(Tier.mid, senseModel("@cf/meta/llama-3.3-70b-instruct-fp8-fast", false).tier); // fp8 never reads as params
    try std.testing.expectEqual(Tier.large, senseModel("claude-fable-5", false).tier);
    try std.testing.expectEqual(Tier.large, senseModel("gpt-5", false).tier);
    try std.testing.expectEqual(Tier.large, senseModel("kimi-k3", false).tier);
    try std.testing.expectEqual(Tier.large, senseModel("deepseek-ai/DeepSeek-R1", false).tier); // uppercase id, no size in name
}

test "senseModel: MoE totals, decimals, uppercase B, millions" {
    try std.testing.expectEqual(Tier.large, senseModel("qwen/qwen3.5-397b-a17b", false).tier); // total 397, not active 17
    try std.testing.expectEqual(Tier.large, senseModel("qwen/qwen3-235b-a22b", false).tier);
    try std.testing.expectEqual(Tier.mid, senseModel("mixtral-8x7b-instruct", false).tier); // 8x7 = 56B
    try std.testing.expectEqual(Tier.mid, senseModel("Qwen/Qwen2.5-72B-Instruct", false).tier);
    try std.testing.expectEqual(Tier.small, senseModel("qwen2.5:1.5b", false).tier);
    try std.testing.expectEqual(Tier.small, senseModel("smollm2:135m", false).tier);
    try std.testing.expectEqual(Tier.small, senseModel("Mistral-Small-24B-Instruct-2501", false).tier);
}

test "senseModel: ctx window caps the tier; light markers read as mid; minimax is not mini" {
    const m8k = senseModel("moonshot-v1-8k", false);
    try std.testing.expectEqual(Tier.small, m8k.tier); // frontier params, 8k window → the budgets must fit the window
    try std.testing.expectEqual(@as(u32, 8), m8k.ctx_k);
    try std.testing.expectEqual(Tier.mid, senseModel("moonshot-v1-32k", false).tier);
    try std.testing.expectEqual(Tier.large, senseModel("moonshot-v1-128k-vision-preview", false).tier);
    try std.testing.expectEqual(Tier.mid, senseModel("gpt-4.1-mini", false).tier);
    try std.testing.expectEqual(Tier.mid, senseModel("gemini-3.5-flash", false).tier);
    try std.testing.expectEqual(Tier.mid, senseModel("glm-4.5-air", false).tier);
    try std.testing.expectEqual(Tier.large, senseModel("minimax/minimax-m2.5", false).tier); // "mini" is not a bounded segment
}

test "senseModel: local hint, catalog local flag, yaml tier pin, ctx defaults" {
    // an unnamed model on a local endpoint is assumed small — never drown it
    try std.testing.expectEqual(Tier.small, senseModel("my-custom-model:latest", true).tier);
    try std.testing.expectEqual(Tier.large, senseModel("my-custom-model:latest", false).tier); // hosted unknown = frontier
    // catalog rows under a local provider are local even without the hint
    try std.testing.expectEqual(Tier.small, senseModel("qwen2.5-coder:7b", false).tier);
    // the yaml pin on the rotating free router wins over the hosted-frontier default
    try std.testing.expectEqual(Tier.small, senseModel("openrouter/free", false).tier);
    // ctx_k is always filled: tier defaults when nothing states it
    try std.testing.expectEqual(@as(u32, 128), senseModel("claude-opus-4-8", false).ctx_k);
    try std.testing.expectEqual(@as(u32, 8), senseModel("hermes3:8b", false).ctx_k);
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
