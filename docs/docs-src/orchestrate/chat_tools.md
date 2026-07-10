# chat_tools

**File:** `src/orchestrate/chat_tools.zig`  
**Module:** `orchestrate`  
**Description:** Defines the tool registry for function-calling agents: tool schemas, parameter validation, and dispatch logic used by chat-based agent interactions.

---

## Purpose Summary

Defines the tool registry for function-calling agents: tool schemas, parameter validation, and dispatch logic used by chat-based agent interactions.

## Key Exports

- `Tool` struct — name, description, parameter schema
- `ToolRegistry` — global tool map
- `register_tool()` — add tool
- `dispatch()` — execute tool by name

## Dependencies

- `worker/tools` — tool dispatch types
- `worker/llm` — LLM function-calling interface

## Usage Context

Used by the AGI worker and chat-based agent interfaces to define available actions.

## Notable Implementation Details

Tool schemas follow JSON Schema format for LLM compatibility. Supports parallel tool calls and structured results.

---

*Documentation generated for nl-veil — chat_tools.zig source analysis.*
