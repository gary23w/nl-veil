//! catalog.zig — a compact, embedded copy of the provider/model catalog + the deploy option sets, mirroring
//! web/public/models.json and the wizard's dropdowns. Kept in-binary (not read from disk) so the Deploy form
//! works with zero external files; the field names + values match the server's DeployReq exactly.

const std = @import("std");

pub const Model = struct { id: []const u8, label: []const u8 };
pub const Provider = struct {
    key: []const u8,
    label: []const u8,
    base_url: []const u8, // sent verbatim; "cloudflare"/"local" are resolved server-side. May contain the
    // "{account}" placeholder (Cloudflare) — resolveBase() substitutes the account id before it's used/sent.
    needs_key: bool,
    models: []const Model,
    needs_account: bool = false, // provider also needs an account id (Cloudflare Workers AI) to build its URL
};

/// Resolve a provider's base_url. If the template carries the "{account}" placeholder (Cloudflare Workers AI),
/// substitute the account id into `out` and return that slice; with no account id, return the "cloudflare"
/// sentinel so the server falls back to its own included/env credentials. Non-templated URLs pass through.
pub fn resolveBase(p: *const Provider, account: []const u8, out: []u8) []const u8 {
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

pub const providers = [_]Provider{
    .{ .key = "anthropic", .label = "Anthropic (Claude)", .base_url = "https://api.anthropic.com/v1", .needs_key = true, .models = &.{
        .{ .id = "claude-opus-4-8", .label = "Claude Opus 4.8" },
        .{ .id = "claude-fable-5", .label = "Claude Fable 5" },
        .{ .id = "claude-sonnet-5", .label = "Claude Sonnet 5" },
        .{ .id = "claude-haiku-4-5", .label = "Claude Haiku 4.5" },
    } },
    .{ .key = "openai", .label = "OpenAI (GPT)", .base_url = "https://api.openai.com/v1", .needs_key = true, .models = &.{
        .{ .id = "gpt-5", .label = "GPT-5" },
        .{ .id = "gpt-4.1", .label = "GPT-4.1" },
        .{ .id = "gpt-4.1-mini", .label = "GPT-4.1 mini" },
        .{ .id = "gpt-4.1-nano", .label = "GPT-4.1 nano" },
        .{ .id = "o4-mini", .label = "o4-mini" },
    } },
    .{ .key = "ollama", .label = "Ollama (local — no key)", .base_url = "http://localhost:11434/v1", .needs_key = false, .models = &.{
        .{ .id = "gpt-oss:20b", .label = "gpt-oss 20B" },
        .{ .id = "qwen2.5-coder:7b", .label = "Qwen2.5 Coder 7B" },
        .{ .id = "qwen2.5:14b", .label = "Qwen2.5 14B" },
        .{ .id = "llama3.1:8b", .label = "Llama 3.1 8B" },
    } },
    // Cloudflare Workers AI via its OpenAI-compatible endpoint. Needs BOTH an account id (built into the URL)
    // and an API token. Leaving both blank sends the "cloudflare" sentinel so a server configured with
    // NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN uses its own (included) credentials instead. See resolveBase().
    .{ .key = "workers-ai", .label = "Cloudflare Workers AI", .base_url = "https://api.cloudflare.com/client/v4/accounts/{account}/ai/v1", .needs_key = true, .needs_account = true, .models = &.{
        .{ .id = "@cf/meta/llama-3.3-70b-instruct-fp8-fast", .label = "Llama 3.3 70B (fast)" },
        .{ .id = "@cf/meta/llama-3.1-8b-instruct", .label = "Llama 3.1 8B" },
        .{ .id = "@cf/qwen/qwen2.5-coder-32b-instruct", .label = "Qwen2.5 Coder 32B" },
    } },
    .{ .key = "groq", .label = "Groq", .base_url = "https://api.groq.com/openai/v1", .needs_key = true, .models = &.{
        .{ .id = "llama-3.3-70b-versatile", .label = "Llama 3.3 70B versatile" },
    } },
    // DeepSeek + Google Gemini — OpenAI-compatible endpoints (mirror web/public/models.json). Added AFTER the
    // existing providers so saved chat_byok indices (anthropic=0, openai=1, ollama=2, workers-ai=3, groq=4) stay
    // valid. Both flow through the standard {base_url}/chat/completions path, so no engine change is needed.
    .{ .key = "deepseek", .label = "DeepSeek", .base_url = "https://api.deepseek.com/v1", .needs_key = true, .models = &.{
        .{ .id = "deepseek-v4-flash", .label = "DeepSeek V4 Flash" },
        .{ .id = "deepseek-v4-pro", .label = "DeepSeek V4 Pro" },
        .{ .id = "deepseek-chat", .label = "DeepSeek Chat" },
    } },
    .{ .key = "google", .label = "Google Gemini", .base_url = "https://generativelanguage.googleapis.com/v1beta/openai", .needs_key = true, .models = &.{
        .{ .id = "gemini-3.5-flash", .label = "Gemini 3.5 Flash" },
        .{ .id = "gemini-3.1-pro-preview", .label = "Gemini 3.1 Pro (preview)" },
        .{ .id = "gemini-2.5-flash", .label = "Gemini 2.5 Flash" },
    } },
    .{ .key = "mock", .label = "Mock (dry run — no calls)", .base_url = "", .needs_key = false, .models = &.{
        .{ .id = "mock", .label = "mock" },
    } },
    // Hugging Face Inference Providers — one hf_ token routes to hundreds of open models across partner
    // providers (Cerebras, Groq, Together, Novita, ...). OpenAI-compatible at router.huggingface.co/v1, so it
    // flows through the standard BYOK path (chat + hive) with no server change. Appended LAST so saved
    // chat_byok / provider indices above stay valid. The default (no suffix) routes to the fastest provider;
    // a model id may carry a ":provider"/":cheapest" suffix if the user wants to pin one.
    .{ .key = "huggingface", .label = "Hugging Face (Inference Providers)", .base_url = "https://router.huggingface.co/v1", .needs_key = true, .models = &.{
        .{ .id = "openai/gpt-oss-120b", .label = "GPT-OSS 120B" },
        .{ .id = "openai/gpt-oss-20b", .label = "GPT-OSS 20B" },
        .{ .id = "deepseek-ai/DeepSeek-V3-0324", .label = "DeepSeek V3" },
        .{ .id = "deepseek-ai/DeepSeek-R1", .label = "DeepSeek R1" },
        .{ .id = "meta-llama/Llama-3.3-70B-Instruct", .label = "Llama 3.3 70B" },
        .{ .id = "meta-llama/Llama-3.1-8B-Instruct", .label = "Llama 3.1 8B" },
        .{ .id = "Qwen/Qwen2.5-72B-Instruct", .label = "Qwen2.5 72B" },
        .{ .id = "Qwen/Qwen2.5-Coder-32B-Instruct", .label = "Qwen2.5 Coder 32B" },
        .{ .id = "mistralai/Mistral-Small-24B-Instruct-2501", .label = "Mistral Small 24B" },
    } },
};

pub const styles = [_][]const u8{ "auto", "build", "build_use", "investigate", "debate" };
pub const stacks = [_][]const u8{ "general", "static", "node" };
// "cast" is the fast scatter-gather type: the lead decomposes the goal, each mind runs ONE moment on its
// slice, then it stops (~1-2 min) and the result is synthesized — vs "continuous" which loops for the whole
// budget. Deploy it from here just like any other swarm, or from the chat.
pub const modes = [_][]const u8{ "continuous", "checkpoint", "refine", "cast" };
pub const minutes = [_]u32{ 0, 5, 15, 30, 60 };
pub const minutes_lbl = [_][]const u8{ "until stopped", "5", "15", "30", "60" };
