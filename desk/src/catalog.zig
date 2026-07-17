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
