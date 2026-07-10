# main

**File:** `src/main.zig`  
**Module:** `root`  
**Description:** Application entry point that initializes all subsystems (config, auth, gateway, orchestration, worker pools) and starts the server event loop.

---

## Purpose Summary

Application entry point that initializes all subsystems (config, auth, gateway, orchestration, worker pools) and starts the server event loop.

## Key Exports

- `main()` — entry point
- `init_subsystems()` — one-time init
- Config types, startup health check

## Dependencies

- All modules — orchestrates full initialization
- `build.zig` — build configuration

## Usage Context

Invoked by the operating system or container runtime. Single entry point for the entire nl-veil server.

## Notable Implementation Details

Performs a dependency-injection style init: each subsystem is constructed, then wired together via a shared context struct. Exits with code 1 if any subsystem fails to start.

---

*Documentation generated for nl-veil — main.zig source analysis.*
