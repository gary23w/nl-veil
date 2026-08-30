# the veil — v1.0.1-beta-7

**The seventh beta, and the one where the veil gets a cloud.** Not a hosted service — *yours*. One click
connects your own Cloudflare account, and from that moment the veil runs on your account's live Workers AI
models, quietly backs your conversations up to your own R2 bucket, and — if you let it — can write a Worker
and put it on the internet at a real URL. There is nothing to paste, nothing to configure, and no server in
the middle: the token is minted for your account and never leaves your machine.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-7-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-7-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-7-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-7-linux-x86_64.zip`** |

Unzip it, then run **`veil.exe`** (Windows) or **`./veil`** (macOS/Linux). That single action starts the
server *and* opens the app.

> **Do NOT download "Source code (zip / tar.gz)"** at the bottom of this page. GitHub attaches those to
> every release automatically — they're the raw repo, and building from them needs the Zig compiler.

## Log in with Cloudflare

The button is in four places: the web app's **Settings**, a card under the **chat composer**, the
**Dashboard**, and the desktop's **Settings**. Click it, approve the consent screen, done.

**It is your account, not ours.** The veil is open source and every copy ships the same public client id —
the way `wrangler` and `gh` do. The token that comes back is minted for *your* Cloudflare account and sealed
in *your* local server's vault. It never reaches the maintainer; Cloudflare redirects the browser to
`localhost`, which is the machine already in front of you.

### Workers AI, synced rather than shipped

Once connected, your account's **real model catalogue** is fetched from Cloudflare and replaces the Workers
AI group in every model picker. The repo carries exactly one model id as a bootstrap default — the list you
choose from is always your account's, never a stale copy checked into a file. Logging in also points chat at
Workers AI automatically, which matters because it has a **free daily allowance** (10,000 neurons/day as of
2026): no paid plan and no card for the base tier. One click in Settings puts you back on local or BYOK.

### Your chats, backed up to your own R2

The first login provisions an `nl-veil` bucket in your account and mirrors your conversations and durable
memories into it, incrementally, in the background — riding the status poll rather than a daemon of its own.
Your data stays local too; this is a copy, not a move. R2 gives 10 GB free with no egress fees, though it
must be **activated once** on your Cloudflare dashboard — until then the card says exactly that, in
Cloudflare's own words.

Deliberately **not** backed up: scheduled-task definitions, whose on-disk form holds real pasted provider
keys. A backup that quietly uploaded your API keys would be a bug with a very long tail.

### An assistant that can deploy

With the build scopes granted, six `cf_` tools join the belt — and *only* when a turn actually holds
credentials, so a user who never connected never even sees them.

| tool | what it does |
|---|---|
| `cf_deploy_worker` | Ship an ES-module Worker from the workspace, get back a live `workers.dev` URL |
| `cf_r2_list` | List your buckets, or the objects in one |
| `cf_r2_put` / `cf_r2_get` | Move files between the workspace and R2 |
| `cf_d1_query` | Run SQL against a D1 (serverless SQLite) database |
| `cf_api` | Any other v4 endpoint — Pages, KV, Queues, Vectorize, routes, logs |

Try it in one sentence: *"write a Worker that returns the current time as JSON and deploy it."*

### You choose how much to give it

The consent screen asks for **four required** permissions — Workers AI read/write, plus two read-only ones
to resolve your account and show who you are. Everything else is **optional and declinable right there**:
Workers Scripts, R2, D1, KV, Pages, Queues, Vectorize, Routes, Tail, Observability. Decline them and you
still log in and chat; a tool that needs one later refuses with Cloudflare's own explanation.

**Never requested at all:** DNS, zones, WAF, billing, or account membership. A tool here can ship an app and
spend your Workers AI allowance; it cannot repoint your domain, weaken your security, or add anyone to your
account. Disconnect any time — the R2 bucket and its contents stay in your account, because they were
always yours.

## Also in this beta

- **Scheduled runs use your login too.** A task firing at 3am now resolves the owner's Cloudflare
  credentials exactly as chat and casts already did — the one turn path a login didn't cover, where the task
  saved fine and then failed every run with a blank key.
- **Token refresh is serialised.** With more callers now sharing one credential, two of them entering the
  refresh window together could each spend the same refresh token; under rotation-with-reuse-detection that
  can revoke the whole grant. One mutex, and a still-valid token is preferred over failing a turn.
- **The OAuth callback page escapes what it echoes.** It is a public route that reflected a query parameter
  and an account display name into HTML.
- **Windows: the consent URL opens in your browser.** It used to open **File Explorer** — `explorer.exe`
  refuses a URL carrying a querystring, and an OAuth consent URL is nothing but querystring. It now goes
  through the shell's protocol handler.
- **Cloudflare Workers AI is back in the model catalogue**, appended last so the desk's saved provider
  indices don't shift.

## Under the hood

Two new modules: `src/config/cf_r2.zig` (backup: bucket provisioning, incremental manifest, per-user
throttle) and `src/worker/cftools.zig` (the `cf_` belt). Credentials resolve **once per turn** and ride the
tool context; blank means the family is neither advertised nor callable, so swarm minds and the CLI are
structurally unable to reach your cloud. File arguments are jailed to the workspace, and `cf_api` refuses
any path that would send your token somewhere other than `api.cloudflare.com`.

709 tests pass. The server cross-compiles clean for x86_64/aarch64 Linux and x86_64/aarch64 macOS alongside
the native Windows build.

*Full changelog: [`v1.0.1-beta-6...v1.0.1-beta-7`](https://github.com/gary23w/nl-veil/compare/v1.0.1-beta-6...v1.0.1-beta-7)*
