# veil sentry

**File:** `src/cli/sentry.zig`
**Module:** `cli`

The [sentry](../worker/sentry.md) from the terminal. Every verb is one authenticated call to the local server's `/api/v1/sentry` routes (admin-gated there); this file shapes requests and prints replies.

| Verb | Does |
| --- | --- |
| `veil sentry` | status: on/off, posture, auto-block, cadence, host firewall, the last scan's counts, rules, findings; then the open findings |
| `veil sentry on` / `off` | watch this machine, or stop (observe posture: nothing on the host changes) |
| `veil sentry scan` | inventory now, every listener with its process and whether it is bound to a network address, then new findings |
| `veil sentry findings [--all] [--since N] [--min low\|medium\|high]` | the findings, open ones by default |
| `veil sentry inventory [--connections] [--persistence]` | the last inventory |
| `veil sentry rules` | the policy, with `[on host]` for rules the firewall has |
| `veil sentry block <port> [--udp] [--out] [--remote IP\|CIDR] [--program PATH] [--note "…"] [--id SLUG]` | add a block rule (`allow` likewise) |
| `veil sentry rm <id>` | drop a rule (and withdraw it from the host if it was applied) |
| `veil sentry posture observe\|enforce` | enforce applies the policy to the host firewall; needs an elevated veil on Windows, root on Linux and macOS |
| `veil sentry auto-block on\|off` | enforce only: quarantine a new network-reachable listener on sight |
| `veil sentry every <seconds>` | the scan cadence (15..3600) |
| `veil sentry allow-port <port>` / `disallow-port <port>` | ports that are fine to see listening |
| `veil sentry baseline` | accept everything seen so far as this machine's normal |
| `veil sentry ack` | mark the findings reviewed |

A 401 or 403 is printed as "admin-only"; a 503 as "this server has no sentry". The reply parsers are the generic JSON walkers at the bottom of the file; the tests pin the verb table against the usage line and the timestamp rendering.
