# cf_tunnel

**File:** `src/config/cf_tunnel.zig`  
**Module:** `config`  
**Description:** The public-URL switch — the official `cloudflared` connector run as a managed child: a confidential quick tunnel by default, or a named tunnel with DNS and Access provisioned on the signed-in Cloudflare account.

---

## Purpose Summary

One switch makes this server reachable at a Cloudflare URL. Turning it on finds `cloudflared` (on PATH, else `{data}/bin`, else fetched once from Cloudflare's GitHub release) and runs it as a child process. By default the address is confidential: a quick tunnel, a random `trycloudflare.com` hostname that changes on every start and puts nothing on the account or on any domain the user owns. With "use my domain", a named tunnel is provisioned through the v4 API instead — tunnel, remotely managed ingress, a proxied CNAME on one of the account's zones, and a Cloudflare Access application that admits only the login's own email when the account has a Zero Trust organization — and its token reaches the connector through the environment. Either mode needs a Cloudflare login to flip. The work runs on a background thread through the phases `installing → provisioning → starting → publishing → live`, and the URL is withheld until Cloudflare's own resolver has published the hostname. The switch position persists: a tunnel left on comes back at boot, and `NL_TUNNEL` / `--tunnel` force it on.

## Key Exports

- `TOKEN_PROVIDER` — `"cf-tunnel"`, the vault slot a named tunnel's token is sealed under
- `State` / `readState` — the per-user `{data}/u{uid}/cf_tunnel.json`: switch, domain choice, account-side ids and names, connector path and hash, last error; ids and names only (a test pins that there is no token field)
- `Phase` — `off`, `installing`, `provisioning`, `starting`, `publishing`, `live`, `err` (reported as `"error"`)
- `configure` — main hands over the process environment the connector inherits and the port the ingress points at, before any route can fire
- `turnOn` / `turnOff` — bring the connector up for a uid, or stop it; `turnOff` with `delete` also removes the tunnel, its DNS record and its Access app from the account and deletes the sealed token
- `bootAsync` — the detached boot thread: restore a switch left on, or force it on
- `shutdown` — kill the live connector so it does not outlive the server; main calls it on an orderly exit and leaves the switch position alone
- `tunnelStatus` / `tunnelSet` — `GET` / `POST /api/v1/oauth/cloudflare/tunnel`: the snapshot any login may read, and the admin-only switch (`{on, delete, use_domain, hostname}`), which answers at once and leaves the phases to the status poll

## Dependencies

- `httpz` + `../gateway/http.zig` — `App` (`cf_api_root`, `open_registration`, vault, auth), `requireUser`, `requireAdmin`, `badReq`, `jstr`
- `cf_oauth.zig` — `resolveToken` (bearer + account id), `readProfile` (the email Access admits), `apiCall` (curl with the bearer in a `-K` file), `CF_PROVIDER`
- `../worker/modelpull.zig` — `sha256HexOfFile` for a fetched connector
- `../worker/browser/util.zig` — `sleepMs` for every wait on the tunnel's plain threads (the log watch, the publish probe, the stop poll, the boot delay). Not `io.sleep`: on Windows that parks the thread on the Io runtime's per-thread alert, and a stray alert there is undefined behaviour in the ReleaseFast build.
- External processes: `cloudflared`, `curl` (release download and the DNS-over-HTTPS probe), `tar` for the macOS archive, `tasklist`/`taskkill` on Windows and `kill` elsewhere

## Usage Context

`main.zig` calls `configure(environ, port)` during startup, registers `tunnelStatus` and `tunnelSet`, embeds this file in its route-gate audit (`ROUTE_MODS`), and calls `bootAsync` just before `listen`, forced by `--tunnel` or an `NL_TUNNEL` value that is non-empty and not `0`. The web Settings section and the desk (`refreshCfTunnel`, `doCfTunnel`) poll the status and send `{on:true, use_domain, hostname}` or `{on:false}`; neither sends `delete`, so removing the account-side objects is API-only. The rest of the safety story lives outside this file: `auth_api.register` refuses any request `http.viaProxy` flags (the headers a tunnel adds), the browser relay's loopback check in `ext_api` does the same, and the login guard buckets on `http.clientAddress` (`Cf-Connecting-Ip`) instead of the one loopback peer every tunneled visitor shares. `main.zig` calls `shutdown` when the desk window closes (app mode, before the listener stops) and when `listen` returns (server-only). A server that is killed runs neither; its connector is found through the pidfile and killed by the next `turnOn`, and in app mode on Windows it also dies with the process's kill-on-close job.

## Notable Implementation Details

- Turning on is refused (400) while open registration is on, without a Cloudflare login, for a hostname that is not lowercase letters, digits, dots and hyphens with at least one dot, and while another flip is in progress. A flip that changes nothing on a running tunnel answers `already:true` rather than restarting, because a restart mints a new address and drops every open session.
- One connector per process, so the phase, URL and flags in the status are process-wide. A non-admin gets blank `url`, `last_error`, `hostname`, `want_hostname` and `zone`; `on`, `use_domain` and `mode` come from the caller's own state file.
- Token handling: every named flip fetches the tunnel token from the API and hands it to `cloudflared tunnel … run` as `TUNNEL_TOKEN` in a cloned environment, never as `--token` on the argv; the copy sealed under `TOKEN_PROVIDER` is not read back anywhere. A quick tunnel runs `cloudflared tunnel … --url http://127.0.0.1:<port>` with no token.
- Start: the child's stdio is ignored and its `--logfile` (`cf_tunnel.log`, emptied at each start) is read every 700 ms for up to 90 s — a named tunnel is up at `Registered tunnel connection`, a quick one when an `https://…trycloudflare.com` address appears; an authentication failure in the log ends the start early. A waiter thread turns a connector that exits while starting, publishing or live into phase `error`; nothing restarts it.
- Publishing: the hostname is checked against Cloudflare's DNS-over-HTTPS endpoint (`cloudflare-dns.com/dns-query`, `type=A`) every 3 s for up to 90 s, and counts as published on status NOERROR with at least one answer (tested). Until then the URL stays out of the status and the server log, because a lookup through the local resolver before the name exists caches NXDOMAIN for `trycloudflare.com`'s 1800 s negative TTL. After the budget the URL is shown anyway, with `published:false`.
- Named provisioning reuses the ids already in the state, step by step: zone (the one the requested hostname is on, matched at a label boundary and the most specific when zones nest, else the first active zone; only the first 50 are listed, and a hostname on none of them is an error) → tunnel `veil-<8 hex>` with `config_src: cloudflare` → hostname (the requested one or `veil.<zone>`, replaced by `veil-<4 hex>.<zone>` when a record not pointing at this tunnel already holds it) → ingress (hostname to `http://127.0.0.1:<port>`, everything else `http_status:404`) → proxied CNAME to `<tunnel>.cfargotunnel.com` → Access → token.
- A hostname change moves the DNS record and the Access app with it. `tunnelSet` clears the effective hostname when the requested one changes. Provisioning then treats the record and app ids still in the state as the old name's and takes both off the account (Access app first, best-effort, a refusal logged with the API's words), unless the lookup finds that same record under the new name, as when the name already in use is asked for explicitly. A move to another zone does the same on the old zone before the zone id is replaced. The new name then gets its own CNAME and, with a Zero Trust organization, its own Access app. Stand-in API tests pin the same-zone change, the zone move and the no-churn case.
- Access is best-effort and zone-level (`/zones/{zone}/access/apps`, the ids this client can be granted): a `self_hosted` app with a 24 h session and one `owner only` allow policy for the login's email. `access` in the status (and "Access: owner only" in the log) is true only for a named tunnel whose state holds a policy id. A quick tunnel keeps the named ids for the next "use my domain" flip and never reports Access (tested). Without Access, the veil's own rate-limited login is the only gate.
- An API refusal that mentions an authentication error, insufficient permissions, "not authorized" or "permission" becomes an instruction to log in with Cloudflare again to grant the tunnel scopes (a login made before those optional scopes existed lacks them); any other error is quoted verbatim (tested).
- Off is verified: the stop kills the in-process child and the pid from `cf_tunnel.pid` (`taskkill /T /F`, or `kill -TERM` escalating to `-KILL`), then polls up to 50 times, 100 ms apart. A survivor leaves the phase at `error` with a message naming the pid and saying the URL stays reachable. `delete` runs only after that: it removes the Access app, DNS record, connections and tunnel best-effort while the login still resolves, and clears the local state either way — without a login, the account-side objects stay and their ids are forgotten.
- The fetched connector is the `latest` release asset for the OS and architecture (Windows amd64/386, Linux amd64/arm64/386/arm, macOS amd64/arm64 `.tgz`), downloaded by curl with a 20 s connect timeout and two retries, then required to run `--version`. Its SHA-256 is logged and stored as `binary_sha256` but not compared with a pinned value, and a copy already in `{data}/bin` is reused without either check.
- API calls hang off `app.cf_api_root`, the root the `cf_` tool belt also uses, so a loopback `NL_CF_API_ROOT` redirects tunnel provisioning as well.
- Boot waits 1.5 s, then acts for the first admin whose login has a Cloudflare profile; when forced with no such admin, it logs a warning and does nothing.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
