# running a server

**Covers:** `src/main.zig` (boot, bind, admin password), `src/config/{lan,server_config,key_vault}.zig`, `src/admin/admin_service.zig`  
**Kind:** operator walkthrough  
**Description:** Getting from a fresh binary to a server other people on your network can log into — first login, the default model, the shared provider key, accounts, and how to keep it private if you would rather.

---

## Start it

A release bundle needs no toolchain: unzip and run `veil` (`veil.exe` on Windows). From source it is `zig build` with Zig 0.16+, which leaves the binary at `zig-out/bin/veil`; `install.ps1` / `install.sh` do the clone-and-build for contributors.

A bare `veil` starts the server **and** opens the desktop window, because that is what a double-click should do. For a headless box, a service manager, or anything that brings up its own UI:

```sh
veil --server-only      # alias: --headless
```

In a `-Dapp=false` build there is no GUI compiled in, so every invocation behaves that way already.

## It listens on every interface by default

This is the fact to read carefully before anything else.

**The default bind is `0.0.0.0`.** Every address this machine answers on, not just loopback. That is deliberate — the point of the thing is that a phone on the sofa or a laptop in the next room can open it, and a loopback default meant everyone had to discover an environment variable before the web UI existed for them at all.

So on a default run, anyone who can reach this machine's IP can reach the login page. Since the program runs arbitrary code as the user who started it, treat that as what it is.

To stay on this machine only, opt in:

```sh
NL_BIND=127.0.0.1 veil          # or NL_BIND=localhost
```

The startup banner tells you which one happened. On a network bind it enumerates the real addresses (`config/lan.zig`) and prints one complete URL per address; on a loopback bind it says *this machine only* and names the variable that did it.

Nothing in the binary touches your firewall — it calls `listen()` and that is all. On Windows, that first bind is what raises the standard firewall dialog; if you dismiss it, the server is listening and other machines still cannot reach it, and the fix is an OS firewall rule, not a `veil` setting.

The port is `NL_PORT`, else `8787`, resolved in one place and shared by the CLI client.

## First login

The admin account is `admin@neuron-loops.local` unless `NL_ADMIN_EMAIL` names another address.

The password depends on how you started it:

| how you started it | the password |
|---|---|
| `NL_ADMIN_PASSWORD` set | yours, applied at boot |
| default (network-reachable) bind, nothing set | **generated**, and written to `data/admin-password.txt` |
| `NL_BIND=127.0.0.1`, nothing set | the seeded default, `changeme` — change it |

The generated case is the ordinary one, so that file is where most first-time logins begin. Open it, copy the line after `admin password:`, log in, and set your own.

Two details that matter:

- **It is stable across restarts.** The server reads the file back before minting anything, because generating a fresh secret every boot while the seeding path quietly discarded it meant the recorded password stopped being the real one from boot two onward.
- **It is made true before it is written.** Seeding only ever *creates* an account; against an existing one it changes nothing. So the server proves the password logs in, rotates it if it does not, and only then writes the file. A file stating a password that was never applied is worse than no file, because the reader stops looking for the real problem.

If you would rather pin your own from the start, set `NL_ADMIN_PASSWORD` (and `NL_ADMIN_EMAIL`) before the first run and no file is written at all.

## Set a default model

**Admin → Default model.** Pick from the same catalog the Settings tab uses. It applies live, with no restart, to everyone who has not chosen their own, and it persists to `data/server-config.json`.

Without it, a brand-new account has to configure a model before it can chat at all — which is a poor first thirty seconds for someone you just handed a login to.

`NL_DEFAULT_MODEL` / `NL_DEFAULT_BASE_URL` **seed** this on a fresh install, for unattended provisioning. Once an admin has set a value in the UI, the stored config wins, so a stale launch script cannot undo it on the next restart.

The same surface carries the thinking and prompting roles (`think_model`, `prompt_model`) if you want different models behind different jobs.

## Set the shared provider key — and understand the trade

A default model nobody can afford to call is not a default. **Admin → keys** stores an instance-wide provider key, sealed in the same vault everyone else's keys live in, under a reserved uid that no real account can hold.

Key resolution for a turn, in order: the key the caller sent → that user's own sealed key for the provider → **the shared server key**.

The trade is deliberate and worth stating plainly, in the words of the code that implements it: once this is set, every user's turns spend the admin's credit. That is exactly what a family or LAN install wants — nobody should have to hold an API key to use the thing — and exactly what a public deployment has to think about first. A user who brings their own key is never silently switched onto yours; their key wins.

Per-account keys are entered in Settings and sealed server-side. They are never stored in the browser and the server never sends one back, only a last-four and a fingerprint — a key in `localStorage` is a key in every XSS.

## Make accounts

Self-signup is **off** by default. The admin creates accounts from the Admin tab (`POST /api/v1/admin/users`, email plus a password of 8–200 characters). To let people sign themselves up instead, start with `NL_OPEN_REGISTRATION=1`.

Everything a new account can and cannot do is on its own page: [accounts and the sandbox](accounts.md). The short version is that a normal account is not trusted with the host.

## Knobs worth knowing

| variable | effect |
|---|---|
| `NL_PORT` | listen port (default 8787) |
| `NL_BIND` | `127.0.0.1` / `localhost` keeps it on this machine; anything else, and the default, binds every interface |
| `NL_ADMIN_EMAIL` · `NL_ADMIN_PASSWORD` | the admin identity, and pinning its password |
| `NEURON_LOOPS_DATA` | move the data directory off the install tree |
| `NL_OPEN_REGISTRATION` | open public signups (default closed) |
| `NL_DEFAULT_MODEL` · `NL_DEFAULT_BASE_URL` | seed the instance default on a fresh install |
| `NL_MAX_TURNS` | chat turns running at once, server-wide (default 64, hard ceiling 256) |
| `NL_MAX_TURNS_PER_USER` | how many one account may hold (default: an eighth of capacity) |
| `NL_KEEPALIVE_REQUESTS` | requests one connection serves before recycling (default 200) |
| `NL_RETENTION_DAYS` | prune run directories inactive this long (default 14; 0 disables) |
| `NL_RATE_RPM` | optional per-provider requests/minute cap for hosted traffic (unset/0 = unlimited) |
| `NL_PRODUCTION` | meter non-admins against their neuron plan instead of unmetered beta use |

Size `NL_MAX_TURNS` to the rate limit of whatever key everyone is sharing, not to the size of the box. `NL_MAX_TURNS_PER_USER` is the one that stops a single busy account starving everybody else.

## Where things live

The install root is the directory the binary sits in — or the repo root, when it is running out of `zig-out/bin`. Under it:

```
data/
  admin-password.txt      a generated admin password, if one was generated
  .desktop_key            the local API key the desk and the CLI read
  auth.sqlite             accounts
  server-config.json      the admin-set defaults
  u{uid}/…                one subtree per account (see the accounts page)
```

`NEURON_LOOPS_DATA` overrides the location of `data/` entirely.

---

Next: [accounts and the sandbox](accounts.md) · [architecture](architecture.md) · the entry point, [main](../main.md)
