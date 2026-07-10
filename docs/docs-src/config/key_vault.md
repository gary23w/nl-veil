# key_vault

**File:** `src/config/key_vault.zig`  
**Module:** `config`  
**Description:** Provides an encrypted, in-memory key vault for storing secrets and cryptographic keys, with optional persistence to disk via authenticated encryption.

---

## Purpose Summary

Provides an encrypted, in-memory key vault for storing secrets and cryptographic keys, with optional persistence to disk via authenticated encryption.

## Key Exports

- `KeyVault` struct — encrypted store
- `get(key)` — retrieve secret
- `set(key, value)` — store secret
- `delete(key)` — remove secret

## Dependencies

- Standard library: crypto (AES-GCM), random, serialization
- No internal dependencies (foundational service)

## Usage Context

Used by every module that handles secrets. Initialized at boot from encrypted disk storage.

## Notable Implementation Details

Data is encrypted with AES-256-GCM before writing to disk. The master key is derived from a system secret via HKDF. Memory is mlocked to prevent swapping.

---

*Documentation generated for nl-veil — key_vault.zig source analysis.*
