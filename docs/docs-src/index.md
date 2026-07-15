# nl-veil — Source Documentation

> Repository: [gary23w/nl-veil](https://github.com/gary23w/nl-veil)  
> Every `.zig` source file across the modules — the server (including the CLI and the server-side chat brain) and the native desktop, veil-desk.

---

## Module Index

### [`admin/`](admin/admin_service.md)
| File | Purpose |
|------|---------|
| [admin_service.md](admin/admin_service.md) | Core admin service — API admin operations and management |

### [`auth/`](auth/)
| File | Purpose |
|------|---------|
| [api_keys.md](auth/api_keys.md) | API key management — creation, rotation, revocation |
| [auth_api.md](auth/auth_api.md) | Authentication HTTP API endpoints |
| [auth_core.md](auth/auth_core.md) | Core authentication logic — tokens, sessions, validation |
| [login_guard.md](auth/login_guard.md) | Login guard middleware — rate limiting, brute-force protection |

### [`config/`](config/)
| File | Purpose |
|------|---------|
| [key_vault.md](config/key_vault.md) | Encrypted key vault — secure storage for secrets/keys |
| [keys_api.md](config/keys_api.md) | Key management HTTP API |

### [`gateway/`](gateway/)
| File | Purpose |
|------|---------|
| [http.md](gateway/http.md) | HTTP gateway — request routing, middleware pipeline |

### [`obs/`](obs/)
| File | Purpose |
|------|---------|
| [audit_log.md](obs/audit_log.md) | Observability audit log — structured event recording |

### [`plan/`](plan/)
| File | Purpose |
|------|---------|
| [billing_seam.md](plan/billing_seam.md) | Billing seam — pricing and metering integration |
| [entitlements.md](plan/entitlements.md) | Entitlements — feature gating by plan level |
| [neurons.md](plan/neurons.md) | Neuron plan definitions — resource allocation models |

### [`worker/chat/`](worker/chat/) — the server-side chat brain
| File | Purpose |
|------|---------|
| [engine.md](worker/chat/engine.md) | The chat brain — the server-side agentic turn loop |
| [service.md](worker/chat/service.md) | Chat REST handlers — convs, messages, events, control |
| [tools.md](worker/chat/tools.md) | Chat tool surface + the shared `/chat/tool` endpoint |

### [`worker/control/`](worker/control/) · [`worker/deploy/`](worker/deploy/) · [`worker/neuron/`](worker/neuron/) — the swarm control plane
| File | Purpose |
|------|---------|
| [control/supervisor.md](worker/control/supervisor.md) | Supervisor — detached swarm processes, re-adoption |
| [control/writer.md](worker/control/writer.md) | Control writer — the swarm control bus (stop / steer / goal) |
| [control/fanout.md](worker/control/fanout.md) | Event fanout — swarm `events.jsonl` cursor + SSE stream |
| [deploy/service.md](worker/deploy/service.md) | Deploy service — cast/deploy + swarm files and lifecycle |
| [neuron/client.md](worker/neuron/client.md) | Neuron client — the neuron-db memory bridge (fail-open) |
| [sched.md](worker/sched.md) | Scheduled tasks — each run is a server chat conversation |

### [`worker/`](worker/) — the runtime
| File | Purpose |
|------|---------|
| [agi.md](worker/agi.md) | AGI worker core — autonomous reasoning loop |
| [bufedit.md](worker/bufedit.md) | Buffer editor — file editing operations |
| [commons.md](worker/commons.md) | Worker common utilities — shared helpers |
| [crawl.md](worker/crawl.md) | Web crawler — resource discovery and fetching |
| [hyperspace.md](worker/hyperspace.md) | Hyperspace — vector embedding and similarity search |
| [llm.md](worker/llm.md) | LLM integration — model inference, prompt management |
| [locs/atlas.md](worker/locs/atlas.md) | Atlas — geospatial location services |
| [oscillation.md](worker/oscillation.md) | Oscillation — adaptive recursion and state exploration |
| [rsi.md](worker/rsi.md) | RSI — recursive self-improvement engine |
| [run.md](worker/run.md) | Run loop — main worker execution cycle |
| [tools.md](worker/tools.md) | Tool system — function/tool definitions and dispatch |
| [vcs.md](worker/vcs.md) | VCS integration — version control operations |
| [writer.md](worker/writer.md) | Writer — output generation and formatting |

### [`desk/`](desk/) — the native desktop, veil-desk (Zig + raylib)
| File | Purpose |
|------|---------|
| [main.md](desk/main.md) | Entry point — borderless raylib window, render loop, tabs |
| [chat.md](desk/chat.md) | Chat tab client — sends to the server chat brain, streams + steers (local fallback) |
| [llm.md](desk/llm.md) | LLM client — streaming, SSE/NDJSON, tool-call recovery |
| [store.md](desk/store.md) | Shared state — lock-guarded records + rings across threads |
| [poller.md](desk/poller.md) | The IO thread — fleet liveness, run scan, event tail, notifications |
| [scan.md](desk/scan.md) | Filesystem layer — reads veil run dirs for the dashboard |
| [neuron.md](desk/neuron.md) | Hippocampus client — the neuron-db bridge (fail-open) |
| [netcli.md](desk/netcli.md) | Server client — retry/triage wrapper over httpc |
| [httpc.md](desk/httpc.md) | HTTP client — curl-free raw-socket loopback |
| [theme.md](desk/theme.md) | Theme + widgets — immediate-mode raylib UI, Tokyo Night |
| [mdutil.md](desk/mdutil.md) | Markdown util — block classification, math, inline cleanup |
| [tray.md](desk/tray.md) | System tray — icon + native toasts (Windows), no-op on POSIX |
| [catalog.md](desk/catalog.md) | Model catalog — provider/model/option sets for the picker |
| [secrets.md](desk/secrets.md) | Key at rest — DPAPI-sealed on Windows, plain file on POSIX |
| [log.md](desk/log.md) | Logger — ring buffer to veil-desk.log + the F12 overlay |

---

## Cross-Cutting Concerns

| Module | Role |
|--------|------|
| `admin/` | Administrative API surface — system management |
| `auth/` | Authentication & authorization — API keys, sessions, guards |
| `config/` | Configuration & secrets — encrypted key vault, key management |
| `gateway/` | HTTP ingress — routing, middleware, request lifecycle |
| `obs/` | Observability — audit logging, telemetry |
| `plan/` | Plan & billing — entitlements, metering, resource models |
| `worker/chat/` | The server-side chat brain — the agentic turn loop, REST surface, tools |
| `worker/control/` · `deploy/` · `neuron/` | The swarm control plane — deploy, supervise, stream, steer, memory bridge |
| `worker/` | Worker runtime — LLM, tools, crawling, RSI, editing, VCS, scheduled tasks |
| `desk/` | veil-desk — the native desktop dashboard (Zig + raylib): chat, casts, monitoring |

---

### Build & Entry

- [`main.md`](main.md) — Application entry point and service initialization
- _(build.zig is build metadata, documented inline in main.md)_
