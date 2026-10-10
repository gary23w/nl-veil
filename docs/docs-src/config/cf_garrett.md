# cf_garrett

**File:** `src/config/cf_garrett.zig`
**Module:** `config`

This module resolves the authenticated user's Agent Garrett deployment and derives its credentials. Deployment and removal live in `cf_tot.zig`; tool discovery and calls live in `worker/garrett.zig`.

## Deployment and credentials

The v1.1.12 deployment includes the edge MCP Worker, private execution Worker, dedicated Cloudflare Container and R2 storage. It enables the complete 166-tool catalogue. Settings calls the native launcher from **Deploy security tools**; `veil --tater garrett launch` uses the same route.

`tokenWith` derives secrets with HMAC-SHA256 under the server key, scoped to the label, user, Cloudflare account and generation. The state file records the address, account and generation. `credsFor` reconstructs the user's MCP URL and bearer; no deployment returns null. The MCP bearer is not recorded in the desktop's settings or transcript. A swarm receives its credential pair in its private run credentials like its model key.

## Exports

- `SCRIPT`, `STATE_FILE`: the public script name and shared Cloudflare state file.
- `MCP_LABEL`, `ACCESS_LABEL`, `SESSION_LABEL`: derivation labels for MCP authentication, the chat password and session secret.
- `tokenWith`: derive a labelled secret for the selected account and generation.
- `Creds`, `credsFor`: obtain the user's MCP URL and bearer in the caller's allocator.

## Feature opt-ins

Chat resolves the pair when the message carries `garrett: true`, set by the desktop's **Agent Garrett: on/off** control or `veil chat --garrett`. Swarm deployment resolves it when its form enables Agent Garrett. Tater-tots use their `garrett` setting, controlled in the form or with `/garrett on|off`.

An opted-in online turn with its own credential pair can receive the complete typed tool catalogue, including a sandboxed turn. This does not grant another user's credentials or change the separate local-machine bridge choice.

See [security tools](../guide/security-tools.md) for deployment requirements and [the MCP client](../worker/garrett.md) for discovery and dispatch.
