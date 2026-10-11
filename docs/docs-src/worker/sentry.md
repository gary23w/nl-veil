# sentry

**File:** `src/worker/sentry.zig`
**Module:** `worker`

The sentry is the veil as a working firewall and blue-team watch for the machine it is deployed on. Agent Garrett looks out at domains, hashes and CVEs from the cloud; the sentry looks in. It runs inside the server process on the user's own computer, takes an inventory the operating system already knows how to give, diffs it against the baseline the user accepted, writes what changed as findings, and in the enforce posture applies a policy of allow and block rules to the host's own firewall.

## The inventory

Every scan (`NL_SENTRY_EVERY`, 60 s by default, 15..3600) runs the OS's own tools as argv arrays, never a shell, and parses their text:

| Platform | Listeners and connections | Firewall state | Startup and scheduled entries |
| --- | --- | --- | --- |
| Windows | `netstat -ano` + `tasklist /fo csv /nh` for process names | `netsh advfirewall show allprofiles state` | `reg query` of the four Run/RunOnce keys, `schtasks /query /fo csv /nh` (Microsoft's own tasks and disabled ones left out), the two Startup folders |
| Linux | `ss -tunapH` | `ufw status`, else an nftables input hook | `crontab -l`, enabled systemd unit files (system and user), `/etc/cron.d`, `~/.config/autostart` |
| macOS | `lsof -nP -iTCP -iUDP` | `socketfilterfw --getglobalstate` | LaunchAgents and LaunchDaemons folders, `crontab -l` |

A UDP socket on an ephemeral port (49152 and up) is a client, not a service, and is skipped. Every parser is a pure function over text, tested on captured output of each tool.

## Keys, baseline, findings

A listener's identity across scans is `proto|addr|port|process` (the pid changes on restart). A persistence entry is its own line. An outbound connection is remembered only when it goes to a public address on a port outside the routine set (80, 443, 53, 853, 123, 22, mail, VPN and push ports), keyed by `(process, remote port)`.

The first scan with no baseline **adopts** the machine as it is: a fresh install must not drown its user in a hundred findings about Windows services. After that, every key the baseline does not cover is reported once and remembered in `noted`; `sentry_set baseline=true` (or `veil sentry baseline`) moves everything noted into the baseline.

| Finding | Severity | When |
| --- | --- | --- |
| `new_listener` | high / low / info | a listener not in the baseline, bound to a network address / to loopback / to an allowlisted port |
| `self_exposed` | low / medium | the veil itself listens on a network address; medium when registration is open |
| `new_persistence` | medium | a Run key, scheduled task, startup item, cron line, unit or launch agent not in the baseline |
| `new_outbound` | medium | a process opens a connection to a public address on a port it has not used before |
| `firewall_off` / `firewall_on` | high / info | the host firewall state changes (medium when only one Windows profile is off) |
| `quarantined` | high | auto-block put an inbound block on a new network-reachable listener |
| `rule_applied` / `rule_failed` / `rule_removed` | info / medium / info | the host firewall accepted, refused or dropped a rule |
| `listener_gone` / `persistence_gone` | info | a baseline entry disappeared (once) |
| `baseline` / `posture` / `scan_error` | info | the baseline was adopted or accepted, the posture or switch changed, an inventory command could not run |

Findings live in a ring of 256 in memory, are appended to `{data}/_sentry/events.jsonl`, and carry a monotonic `seq`. `acked` marks the ones reviewed; the chat's system prompt names how many are still open.

## The firewall

The policy (`{data}/_sentry/policy.json`) holds up to 64 rules: action (allow/block), direction (in/out), protocol, port, an optional remote IP or CIDR, an optional program path, a note. A rule must narrow on something; a remote must be made of address characters; a program path cannot carry quotes or control characters; an id is a slug. Values travel as argv elements, so this is about shape, not quoting.

| Posture | What happens |
| --- | --- |
| observe (default) | the policy is a plan; nothing on the host changes |
| enforce | every rule is applied to the host firewall and reconciled on each scan; switching back withdraws them all |

Every host rule is named `veil-sentry:<id>`, and listing, removing and withdrawing only ever name that prefix: a rule the sentry did not write is not its to touch.

| Platform | Apply | List | Remove |
| --- | --- | --- | --- |
| Windows | `netsh advfirewall firewall add rule name=veil-sentry:<id> dir=… action=… protocol=… localport/remoteport=… remoteip=… program=…` | `show rule name=all`, filtered by the prefix | `delete rule name=veil-sentry:<id>` |
| Linux | a table of our own, `inet veil_sentry`, with input and output chains; `nft add rule … drop/accept comment "veil-sentry:<id>"` | `nft -a list table inet veil_sentry` | `nft delete rule … handle N`; observe drops the whole table |
| macOS | `pf.rules` under `_sentry/`, loaded into the `veil-sentry` anchor with `pfctl -a veil-sentry -f` | the file | the file rewritten; observe flushes the anchor |

Enforcement needs the rights the OS demands: an elevated veil on Windows, root for nft and pf. Without them the rule is recorded, `last_error` says what to do, and the sentry keeps observing. A program match exists only on Windows; nft and pf keep it in the policy but cannot narrow on it. On macOS the anchor is evaluated only once `/etc/pf.conf` references it, which the error line says.

**Auto-block** (`auto_block`, enforce only): a new listener bound to a network address, not in the baseline, not on the allowlist and not one of the veil's own ports, gets an inbound block for its port on sight, named `auto-<proto>-<port>`, so one `sentry_rule op=remove` lifts it. Nothing on loopback is ever blocked, and the veil never blocks itself.

## The belt

Six verbs, advertised to an admin turn served from the watched machine (a compact belt carries them only once the sentry is on): `sentry_status`, `sentry_findings`, `sentry_scan`, `sentry_rules`, `sentry_rule`, `sentry_set`. They sit at `security/sentry` on the [tool map](chat/belt.md). `run` is the one dispatch; a null Sentry (a mind, the CLI executor, a sandboxed turn) is the refusal. `doctrine` is the line the chat's system prompt carries while the sentry is on: posture, host firewall, rule count and the open-finding count, with the instruction to read the findings before pronouncing the machine clean.

## Exports

- `Sentry`: `init`, `configure`, `scan`, `addRule`, `removeRule`, `set`, `statusJson`, `findingsJson`, `rulesJson`, `inventoryJson`, `doctrine`, `enabled`, `everySecs`, `posture`, `ackedSeq`.
- `SCHEMA`, `isTool`, `run`: the belt.
- `capture`, `Snapshot`, the parsers (`parseNetstat`, `parseSs`, `parseLsof`, `parseNetshProfiles`, `parseRegRun`, `parseSchtasks`, `parseCrontab`, `parseUnitFiles`, `nameByPid`, `splitHostPort`).
- `backend`: `apply`, `remove`, `listPresent`, `withdrawAll`, `netshArgs`, `nftArgs`, `pfLine`, `parseNetshRuleNames`, `parseNftHandles`.
- `listenerKey`, `persistKey`, `outboundKey`, `exposedAddr`, `privateAddr`, `ruleFromSpec`.

The routes and the background thread are [sentry_api](sentry_api.md); the terminal face is [veil sentry](../cli/sentry.md); the user's guide is in [security tools](../guide/security-tools.md).
