# nl-veil — Source Documentation

> Generated: Thu 2026-07-09 21:47 UTC  
> Repository: [gary23w/nl-veil](https://github.com/gary23w/nl-veil)  
> 32 `.zig` source files documented across 8 modules.

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

### [`orchestrate/`](orchestrate/)
| File | Purpose |
|------|---------|
| [chat_tools.md](orchestrate/chat_tools.md) | Chat tool definitions — function calling registry |
| [control_writer.md](orchestrate/control_writer.md) | Control-plane writer — state mutation orchestration |
| [deploy_service.md](orchestrate/deploy_service.md) | Deploy service — deployment lifecycle management |
| [neuron_client.md](orchestrate/neuron_client.md) | Neuron client — inter-agent communication |
| [supervisor.md](orchestrate/supervisor.md) | Supervisor — agent lifecycle, health, coordination |
| [tail_fanout.md](orchestrate/tail_fanout.md) | Tail fanout — log streaming and event distribution |

### [`plan/`](plan/)
| File | Purpose |
|------|---------|
| [billing_seam.md](plan/billing_seam.md) | Billing seam — pricing and metering integration |
| [entitlements.md](plan/entitlements.md) | Entitlements — feature gating by plan level |
| [neurons.md](plan/neurons.md) | Neuron plan definitions — resource allocation models |

### [`worker/`](worker/)
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

---

## Cross-Cutting Concerns

| Module | Role |
|--------|------|
| `admin/` | Administrative API surface — system management |
| `auth/` | Authentication & authorization — API keys, sessions, guards |
| `config/` | Configuration & secrets — encrypted key vault, key management |
| `gateway/` | HTTP ingress — routing, middleware, request lifecycle |
| `obs/` | Observability — audit logging, telemetry |
| `orchestrate/` | Orchestration — deployment, supervision, inter-agent comms |
| `plan/` | Plan & billing — entitlements, metering, resource models |
| `worker/` | Worker runtime — LLM, tools, crawling, RSI, editing, VCS |

---

### Build & Entry

- [`main.md`](main.md) — Application entry point and service initialization
- _(build.zig is build metadata, documented inline in main.md)_
