//! catalog.zig — a compact, embedded copy of the provider/model catalog + the deploy option sets, mirroring
//! web/public/models.json and the wizard's dropdowns. Kept in-binary (not read from disk) so the Deploy form
//! works with zero external files; the field names + values match the server's DeployReq exactly.

pub const Model = struct { id: []const u8, label: []const u8 };
pub const Provider = struct {
    key: []const u8,
    label: []const u8,
    base_url: []const u8, // sent verbatim; "cloudflare"/"local" are resolved server-side
    needs_key: bool,
    models: []const Model,
};

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
    .{ .key = "workers-ai", .label = "Cloudflare Workers AI (included)", .base_url = "cloudflare", .needs_key = false, .models = &.{
        .{ .id = "@cf/meta/llama-3.3-70b-instruct-fp8-fast", .label = "Llama 3.3 70B (fast)" },
        .{ .id = "@cf/meta/llama-3.1-8b-instruct", .label = "Llama 3.1 8B" },
        .{ .id = "@cf/qwen/qwen2.5-coder-32b-instruct", .label = "Qwen2.5 Coder 32B" },
    } },
    .{ .key = "groq", .label = "Groq", .base_url = "https://api.groq.com/openai/v1", .needs_key = true, .models = &.{
        .{ .id = "llama-3.3-70b-versatile", .label = "Llama 3.3 70B versatile" },
    } },
    .{ .key = "mock", .label = "Mock (dry run — no calls)", .base_url = "", .needs_key = false, .models = &.{
        .{ .id = "mock", .label = "mock" },
    } },
};

pub const styles = [_][]const u8{ "build", "build_use", "investigate", "debate" };
pub const stacks = [_][]const u8{ "general", "static", "node" };
pub const modes = [_][]const u8{ "continuous", "checkpoint", "refine" };
pub const minutes = [_]u32{ 0, 5, 15, 30, 60 };
pub const minutes_lbl = [_][]const u8{ "until stopped", "5", "15", "30", "60" };
