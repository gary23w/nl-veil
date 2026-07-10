# catalog

**File:** `desk/src/catalog.zig`  
**Module:** `desk`  
**Description:** An embedded, compile-time copy of nl-veil's provider/model catalog and swarm-deploy dropdown option sets, plus a Cloudflare {account} URL resolver, so the desktop Deploy form works with zero external files.

---

## Purpose Summary

Provides veil-desk's model picker and Deploy form with a static, in-binary catalog of LLM providers and their models, mirroring the server's web/public/models.json and matching the server DeployReq field names/values exactly. It exists so the desktop app can populate provider/model dropdowns and swarm-deploy options without reading any file from disk, and it supplies resolveBase() to turn a Cloudflare base_url template into a real URL (or a safe sentinel).

## Key Exports

- `Model` — struct { id, label } naming one selectable model
- `Provider` — struct { key, label, base_url, needs_key, models, needs_account=false } describing one provider; base_url is sent verbatim and may hold a `{account}` placeholder
- `resolveBase(p, account, out)` — substitutes a trimmed account id into a provider's `{account}` base_url template (writing into caller buffer `out`); returns the raw base_url when non-templated, and the literal "cloudflare" sentinel when no account id is given or the result won't fit `out`
- `providers` — comptime array of 9 Provider entries (anthropic, openai, ollama, workers-ai, groq, deepseek, google, mock, huggingface — order-stable so saved chat_byok/provider indices stay valid)
- `styles` — ["auto","build","build_use","investigate","debate"]
- `stacks` — ["general","static","node"]
- `modes` — ["continuous","checkpoint","refine","cast"] swarm run modes
- `minutes` / `minutes_lbl` — parallel u32 budget values {0,5,15,30,60} and their labels (0 = "until stopped")

## Dependencies

- std
- log.zig (log.trace in resolveBase)
- mirrors web/public/models.json (the server's provider catalog)
- field names/values must match the server's DeployReq contract
- consumed by veil-desk's Deploy form / model-picker UI

## Usage Context

Read by veil-desk's Deploy/model-picker UI when the user opens the swarm-deploy form or chat BYOK selector: the UI iterates `providers` to render the provider dropdown, each provider's `models` for the model dropdown, and `styles`/`stacks`/`modes`/`minutes(_lbl)` for the remaining deploy controls. When a request is assembled, the UI calls `resolveBase()` to produce the base_url actually sent to the server. Because it is compiled into the binary, no models.json needs to ship or be read at runtime.

## Notable Implementation Details

Everything is comptime-constant data baked into the binary — the entire point is zero external files, so this file is a data table plus one small function, not a state machine. The one piece of real logic is resolveBase(): it finds the literal \"{account}\" marker in base_url, trims whitespace from the account id, and memcpy's pre+account+post into the caller-supplied `out` buffer, returning a slice of it. It never allocates — the caller owns `out`, and the function silently falls back to the literal string \"cloudflare\" in two cases: no account id after trimming, or when pre+acct+post would overflow `out`. Per the base_url doc-comment, the \"cloudflare\" and \"local\" strings are resolved server-side; in practice resolveBase only ever emits \"cloudflare\" (a server preconfigured with NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN then uses its own included Workers AI credentials when the user leaves account/key blank). Note that no provider in this catalog actually carries a \"local\" base_url: ollama's base_url is the literal \"http://localhost:11434/v1\" and the mock provider's base_url is empty \"\" (a dry-run provider that makes no calls). The biggest gotcha is ORDERING: provider entries are append-only — deepseek/google were added after the original five and huggingface appended last, specifically so persisted chat_byok/provider indices (anthropic=0, openai=1, ollama=2, workers-ai=3, groq=4) remain valid; reordering would silently remap saved user selections. The source explicitly describes deepseek, google, workers-ai, and huggingface as OpenAI-compatible endpoints flowing through the standard {base_url}/chat/completions path with no engine/server change (it makes no such claim about anthropic). Provider flags encode UI requirements: needs_key gates the API-key field, needs_account (only workers-ai) gates the account-id field and is what makes base_url carry the `{account}` template. Model ids are current-as-of-authoring names (e.g. claude-opus-4-8, gpt-5, gemini-3.5-flash) and huggingface ids may carry an optional \":provider\"/\":cheapest\" routing suffix.

---

*Documentation generated for nl-veil — desk/catalog.zig source analysis.*
