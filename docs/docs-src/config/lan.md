# lan

**File:** `src/config/lan.zig`  
**Module:** `config`  
**Description:** Which addresses this machine is reachable at — so startup can print a URL somebody can actually type on another device.

---

## Purpose Summary

The server binds every interface by default, and "http://\<this machine\>:8787" is useless advice. This module shells out to the per-OS command (`ipconfig` on Windows, `ifconfig` on macOS, `hostname -I` elsewhere) and extracts the host's real IPv4 addresses, space-joined. It lives in its own file for one practical reason the header spells out: src/tests.zig does not import main.zig, so a test written beside the first version of this parser was silently collected by nothing.

## Key Exports

- `looksLikeIpv4` — four dot-separated decimal octets, 0–255. Hand-rolled because std.net is gone in Zig 0.16 and std.Io.net offers no parser
- `isUninteresting` — filters loopback (127.), link-local (169.254.), wildcard (0.), and mask (255.) prefixes — addresses nobody can usefully open from another machine
- `parseAddresses` — extract host addresses from the command output into a caller buffer, de-duplicated
- `addresses` — run the per-OS command and parse it

## Dependencies

- `std` + `builtin` only (`std.process.run` for the shell-out; per-OS switch on `builtin.os.tag`)

## Usage Context

A startup-banner helper: `addresses` produces the one string needed exactly once at boot. Shelling out is deliberate — Zig 0.16's std.Io exposes no interface enumeration and no getsockname, and the alternative is per-OS FFI for a single startup string.

## Notable Implementation Details

- `parseAddresses` is LINE-aware, not token-aware, and that distinction is the whole function: tokenising `ipconfig` wholesale also picks up the Default Gateway and the subnet mask — both well-formed IPv4, neither an address this machine answers on. The first attempt happily advertised the router; a test now pins that regression.
- Windows keeps only lines containing "IPv4"; macOS lines containing "inet " (the trailing space excludes inet6); `hostname -I` output is all relevant.
- One address per line (the rest of a Windows line is padding); masks are well-formed addresses by design and are rejected by `isUninteresting`, not the parser.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
