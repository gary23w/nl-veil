# llm

**File:** `src/worker/llm.zig`  
**Module:** `worker`  
**Description:** LLM inference integration: manages model loading, prompt templating, context windows, streaming responses, and retry logic for provider APIs.

---

## Purpose Summary

LLM inference integration: manages model loading, prompt templating, context windows, streaming responses, and retry logic for provider APIs.

## Key Exports

- `LLM` struct — model interface
- `complete(prompt)` — generate text
- `stream_complete()` — streaming response
- `token_count()` — count prompt tokens
- `LLMConfig` — model name, temperature, max_tokens

## Dependencies

- `config/key_vault` — API key storage
- `worker/commons` — config, error types
- Standard library: http client, json, streaming I/O

## Usage Context

Used by AGI worker, RSI engine, and any module requiring language model inference.

## Notable Implementation Details

Supports multiple providers (OpenAI, Anthropic, local models) via an adapter pattern. Context window is managed with a sliding approach — oldest messages are summarized before eviction.

---

*Documentation generated for nl-veil — llm.zig source analysis.*
