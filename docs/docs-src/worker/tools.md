# tools

**File:** `src/worker/tools.zig`  
**Module:** `worker`  
**Description:** Tool-dispatch system: registers available tools, validates call arguments, executes tool functions, and returns structured results to the agent.

---

## Purpose Summary

Tool-dispatch system: registers available tools, validates call arguments, executes tool functions, and returns structured results to the agent.

## Key Exports

- `ToolSet` struct — available tool collection
- `execute(name, args)` — run a tool
- `list_tools()` — enumerate registered tools
- Tool result/error types

## Dependencies

- `worker/commons` — result/error types
- Standard library: json schema validation

## Usage Context

Called by AGI worker action execution and chat_tools dispatch. Central hub for all tool invocations.

## Notable Implementation Details

Tools are defined as Zig structs with a `call` method. The dispatch system uses comptime reflection to validate arguments against schemas at compile time.

---

*Documentation generated for nl-veil — tools.zig source analysis.*
