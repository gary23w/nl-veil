# key_vault

**File:** `src/config/key_vault.zig`  
**Module:** `config`  
**Description:** AES-256-GCM at-rest sealing + a write-only BYOK key vault (seal/open primitives + per-user provider keys).

---

## Purpose Summary

Two layers in one file. The free functions are the sealing primitives: derive the 32-byte server key (from `NL_SECRET`, else a generated `<data>/.server.key`), `seal` plaintext to base64 `nonce|tag|ciphertext`, `open` it back (null on any tamper). On top sits `KeyVault`: per-(uid, provider) provider credentials, sealed with the server key and stored in neuron-db under `kv_<uid>_<provider>`. Users can write, list metadata, and delete — the full key only ever flows back out through `resolve`, into the code that calls the provider.

## Key Exports

- `deriveServerKey` — env `NL_SECRET` (SHA-256) or the persisted `.server.key` file, generating one on first boot
- `seal` / `open` — the AES-256-GCM at-rest primitives, also used outside the vault
- `KeyVault.put` — validate + seal + store a BYOK key (provider ≤32 chars of `[a-z0-9-_]`; key 1..512 clean chars)
- `KeyVault.resolve` / `Resolved` — the hot read: key + base_url for a (uid, provider), served through a TTL cache
- `KeyVault.putOAuth` / `resolveOAuth` / `OAuthBundle` — an OAuth bundle (access + refresh token, expiry, account id — Cloudflare today) riding the same sealed JSON blob
- `KeyVault.list` / `KeyMeta` — metadata only: provider, last4, SHA-256 fingerprint, base_url, created
- `KeyVault.has` / `del` — existence probe; delete (drops the cache entry immediately)

## Dependencies

- `../worker/neuron/client.zig` — `Neuron`, the store (`get`/`put`/`del`/`scopes`)
- Std: `std.crypto.aead.aes_gcm.Aes256Gcm`, `Sha256`, `std.base64`

## Usage Context

Server key derived and vault constructed in `main.zig`. `config/keys_api.zig` is the per-user HTTP surface; `admin_service` stores the instance-wide key under reserved uid 0 (`SERVER_KEY_UID`); chat's `resolveRole` calls `resolve` per model role per turn; `cf_oauth.zig` uses the OAuth pair; supervisor and deploy import `seal`/`open` directly for their own at-rest data.

## Notable Implementation Details

- Write-only by contract: no API returns the stored key to the person who stored it — `list` gives last4 + fingerprint, enough to recognize a key without recovering it.
- The resolve cache (16 slots, 20s TTL) exists because `Neuron.get` forks neuron.exe under the vault mutex — one turn could pay up to six serialized spawns. Correctness does not ride on the TTL: every in-process writer (`put`/`putOAuth`/`del`) drops the entry immediately, so rotation takes effect on the next resolve; the TTL only bounds an out-of-process CLI writer and how long unsealed material stays resident.
- Definitive absence is cached (the common no-BYOK case); a neuron.exe *failure* is not — "we don't know" must not become "no key" for 20 seconds.
- A plain BYOK key and an OAuth bundle share the provider slot; callers tell them apart by `refresh_token.len`.

---

*Case file grounded in the module's `//!` header and public API.*
