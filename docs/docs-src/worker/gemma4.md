# gemma4

**File:** `src/worker/gemma4.zig`  
**Module:** `worker`  
**Description:** Gemma-4 wire-format rendering and parsing, so the engine can prompt a local Gemma-4 without going through a runtime's own `gemma4` renderer — verified byte-for-byte against the model's shipped chat template.

---

## Purpose Summary

Measured over 30 harness drills — same Q4_K_M weights, same server, changing only *who renders the prompt* — the runtime's built-in renderer scored 18/30 and produced five calls naming tools that were never on the belt (`Browser`, `StopProcess`, `Read`, `Observe`, `Browser::browser_type`): names memorised in pretraining rather than bound from the request. Rendering the prompt here and posting it as a raw completion scored 27/30 with zero invented names. The tools array does reach the model either way — drop it and the model emits no calls at all — but under the runtime's renderer the model does not bind to the *names* it is given. An explicit template override was tried first and is not a fix: the template language cannot reproduce the parameter-schema encoding, and that attempt scored 15/30.

The correctness contract is what makes bypassing a renderer safe: the render is checked byte-for-byte against output produced by the model's own `chat_template.jinja`, with the fixtures embedded in this file's tests. Matching bytes means matching the format the model was trained on, which is the configuration that measured 27/30.

## The format

```
<bos><|turn>system\n{system}{tool decls}<turn|>\n
<|turn>user\n{text}<turn|>\n
<|turn>model\n{text}<turn|>\n                           (assistant prose)
<|turn>model\n<|tool_call>call:NAME{args}<tool_call|>    (assistant tool call)
```

## Key Exports

- `canRenderFamily(family)` — whether this renderer covers the architecture **the backend reported** (not a model id, which users rename freely).
- `renderPrompt(gpa, messages_json, tools_json) ![]u8` — the raw prompt string. Both arguments are the *inner* text of their JSON arrays — the same slices the native chat body splices in — so a caller switching from a chat call to a raw completion passes what it already had.
- `parseCompletion(gpa, text) !Reply` — the completion back into `Reply{ content, thinking, calls }`, with `Call{ name, args_json }`; `Reply.deinit` frees the whole tree.
- The token constants (`BOS`, `MODEL_TURN`, `EOT`, `GEN_SUFFIX`, `ESC`) are public so callers can set stop sequences without re-spelling them.

## Dependencies

Standard library only. The renderer is deliberately free of the HTTP client and the engine, which is what lets its tests pin exact bytes with no server anywhere.

## Usage Context

`worker/builtin_endpoint.zig` renders through it: both `/api/chat` and `/v1/chat/completions` on the built-in engine turn messages + tools into one raw prompt here, run the completion, and parse the answer back into native-shaped tool calls — so callers see an ordinary tool-calling API while the prompt bytes stay the trained ones.

## Notable Implementation Details

- The tool declarations carry a parameter-schema encoding that lives *with* the renderer rather than in a template file — the reason a template override could not reach parity.
- The fixtures are the specification. A change to the render needs a matching fixture produced from the model's own chat template, or the byte contract has quietly stopped being one.
- `thinking` is separated from `content` at parse time, so a reasoning span never leaks into the answer the user reads.
- Unrecognised families are not an error: `canRenderFamily` says no and the caller takes the ordinary chat path.

---

*Case file grounded in the module's `//!` header and public API.*
