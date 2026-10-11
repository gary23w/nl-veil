# Agent Garrett security tools

NL-Veil is the local harness for Agent Garrett. It connects your chat, swarm or tater-tot to a security runtime deployed in your Cloudflare account. The v1.1.12 deployment enables 166 MCP tools: 94 existing security tools and 72 Gary tools for cloud commands, files, tasks, shells and the runtime's other capabilities.

## Deploy once, choose where to use it

Open **Settings → Models**, connect Cloudflare, and choose **Deploy security tools**. Deployment creates the public `veil-garrett` Worker, private `veil-garrett-gary` Worker, dedicated Gary Container and `veil-garrett-gary-state` R2 bucket. Containers and R2 must be available on the account. Reconnect an existing Cloudflare login once to authorize Containers access.

The edge Worker handles the chat and MCP endpoint. Gary's Linux execution runs in Cloudflare Containers. Source, preparation snapshots and runtime state are stored in R2. Cloudflare performs the initial build when Gary is first requested. No Docker on your computer and no separate Linux host are required. Building can take several minutes; the Settings button shows an animated loading bar throughout upload and preparation.

Choose which feature receives the toolset:

| Feature | Enable it | Change it later |
| --- | --- | --- |
| Chat | Click **Agent Garrett: off** beside auto-loop | Click the same label to switch it off |
| Swarm | Check **Agent Garrett** in the deploy form | The choice applies to that deployed swarm |
| Tater-tot | Check **Agent Garrett** in the deploy form | Send `/garrett on` or `/garrett off` |
| CLI chat | Run `veil chat --garrett` | Start a chat without that flag |

Tools appear individually as `security_<upstream_name>`, with typed argument schemas. For example, `security_gary_bash` accepts a command, a boolean background flag and a numeric timeout. `garrett_tools` lists the current catalogue with schemas; `garrett` remains a compatibility wrapper accepting a tool name and an argument object. Discovery can show the edge tools first while Gary is still building, then the full catalogue once Gary is ready.

## Protect yourself through the local harness

Use NL-Veil for local evidence and control. The Cloudflare Container sees its own cloud filesystem; it does not automatically see your laptop's disks, installed programs or local network. A local file must be read through the harness or supplied explicitly before a cloud tool can analyze it. A tater-tot's separate **let it use THIS machine** checkbox grants the local bridge for that deployment.

| Situation | Prompt to start with | What to check |
| --- | --- | --- |
| Suspicious email or message | “Extract and defang the indicators in this pasted message with `security_ioc_extract`. Explain what each indicator means and preserve the original text.” | The result contains the supplied indicators and distinguishes evidence from interpretation. |
| Unexpected local activity | “Read the log file I specify through the local harness, build a timeline, extract indicators, and compare them with the available reputation and vulnerability tools.” | Local evidence came from the named file; cloud results identify their sources and timestamps. |
| Domain or account exposure | “Check my domain's DNS, certificate transparency and email security posture. Report changes and save the supporting records.” | The domain and records match your request; follow-up changes remain under your control. |
| A service you depend on changes | “Create a tater-tot to monitor my health endpoint and pinned public page. On a tripwire, investigate with Agent Garrett and save the evidence.” | Guard cadence and alert configuration match your needs; the local mirror retains events. |
| A new vulnerability affects you | “Compare this software version and configuration with current CVE, KEV and EPSS information, then produce a prioritized verification plan.” | Version and configuration came from your supplied evidence; exploitability is verified separately. |

For continuous observation, configure a tater-tot guard and choose its posture and leash. Those tater-tot settings remain separate from the security-tool opt-in. See [the day after](day-after.md) for guard commands, event-chain verification and the local run folders.

## The sentry: the veil as your machine's firewall and watch

Agent Garrett looks out from the cloud. The **sentry** looks in: it runs inside the veil on the computer the veil is installed on, needs no Cloudflare account, and never sends anything anywhere. Every minute it inventories what the operating system already knows (which ports are listening and which process holds each one, where established connections go, what starts at boot or on a schedule, whether the host firewall is on), compares that with the baseline you accepted, and records what changed as **findings** with a severity. The chat is told how many findings await review, so the next question you ask about your machine is answered by a model that already knows a new port opened last night.

| Do | How |
| --- | --- |
| Turn it on | `veil sentry on`, the **Sentry** rows in the desktop's Settings, `sentry_set enabled=true` in a chat, or `NL_SENTRY=1` for a fresh install |
| See what is exposed right now | `veil sentry scan`, or ask the chat "what is listening on this machine?" (it calls `sentry_scan`) |
| Review findings | `veil sentry findings`, the open findings in `veil sentry` and the desktop's Dashboard, or `sentry_findings` in a chat |
| Say "that is my machine" | `veil sentry baseline` after you have looked; `veil sentry ack` marks the findings reviewed without changing the baseline |
| Close a port to the network | `veil sentry block 4444` (add `--udp`, `--out`, `--remote 203.0.113.0/24`, `--program C:\path\to.exe` as needed) |
| Make the rules real | `veil sentry posture enforce` applies the policy to Windows Defender Firewall, nftables or pf, naming every rule `veil-sentry:<id>`; `posture observe` withdraws them all. Enforcement needs an elevated veil on Windows and root on Linux or macOS; without that the rule is recorded and the status says why it was not applied |
| Quarantine on sight | `veil sentry auto-block on` (enforce only): a new listener bound to a network address that is not in the baseline or on the allowlist gets an inbound block for its port at once, named `auto-tcp-<port>`, and one `veil sentry rm` lifts it |

The first scan adopts the machine as it is, so a fresh install reports nothing until something changes. The veil's own ports are never reported or blocked, and nothing on loopback is ever blocked. Everything lives under `{data}/_sentry/`: `policy.json` (switch, posture, rules, allowlist), `baseline.json`, `state.json`, `events.jsonl` (every finding, append-only). Rule changes and posture switches are written to the audit log. The sentry does not sniff traffic, inject into processes or hide: it reads what `netstat`, `ss`, `lsof`, `reg`, `schtasks`, `crontab`, `systemctl` and `netsh` print, and it changes the host firewall only in the posture you chose. See [the sentry's source notes](../worker/sentry.md) for the inventory each platform gets and the exact firewall commands.

Together they are the two halves of a blue team on your own desk: the sentry notices a new listener or a new scheduled task and names the process; Agent Garrett takes the hash, the domain it talks to or the task's command line and tells you what the world knows about it.

## Lab and red-team work

The same runtime can inventory an authorized lab, run selected checks, preserve findings and traffic, and organize retests. Give it an explicit target set, a goal and the expected evidence. For example: “Inventory the services in my supplied lab scope, save the results, identify candidate weaknesses and propose the next verification step.” For a retest: “Use the saved finding and its traffic to verify whether my fix changed the observed behavior, then record the result.”

The deployment enables active and Gary tools. Its tool catalogue is not a statement that every command has been exercised against every target. Choose the actions appropriate to the environment you are testing, and inspect the resulting evidence in NL-Veil.

## Verify the connection

Turn Agent Garrett on in chat and ask: “Call `security_gary_bash` with `printf 'hello from Gary\n'; uname -s`, then show the exact output.” The command should run in the cloud Container and report `Linux`. Use `security_gary_shell_list` to inspect cloud shell sessions. `security_ioc_extract` can be checked with a synthetic domain and documentation address without contacting a target.

MCP credentials stay on the server for desktop and CLI chat calls. The MCP endpoint requires its bearer token, and NL-Veil resolves credentials for the authenticated user's own deployment. Remove stops the Container and deletes the two Workers; R2 source and snapshots remain for recovery. If Cloudflare refuses removal, NL-Veil reports the failure and keeps deployment state so it can be retried.

## Licenses and corresponding source

NL-Veil code uses its [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.12/LICENSE). Gary includes modified [ARTEX](https://github.com/Hinln/ARTEX) source under [AGPL-3.0](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-LICENSE). The [Gary notice](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-NOTICE), [source archive](https://github.com/gary23w/nl-veil/raw/refs/tags/v1.1.12/cloud/gary-source.tar.gz), and [Cloudflare build sources](https://github.com/gary23w/nl-veil/tree/v1.1.12/cloud) are public and included in every full release bundle. Dependencies retain their own licenses.

## Tater-tot schema discovery

Tater-tots see every available Garrett tool during planning. Before using a `security_*` tool, they call `tool_schema` with its exposed name to obtain the complete input schema. Arrays, nested objects, booleans and numbers retain their original types. This avoids sending all 166 schemas in every model request. The tater-tot must have Agent Garrett enabled and its deployment connection ready.
