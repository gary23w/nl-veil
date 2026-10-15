# Agent Garrett security tools

NL-Veil connects your chat, swarm, or tater-tot to the Agent Garrett service through authenticated MCP. Garrett manages the subscription, agent deployment, API keys, persistent cloud memory, and automatic backend updates.

## Connect once, choose where to use it

Open **Settings → Agent Garrett**, then **Open Garrett dashboard**. Sign in with Cloudflare, activate Trial or Agent, and deploy your agent. Generate an API key in the dashboard. Return to NL-Veil, choose **Paste key / MCP config**, and **Connect Agent Garrett**. You can paste either the generated key or the dashboard's copied MCP configuration.

NL-Veil supplies the service endpoint automatically, checks authenticated MCP initialization, and discovers the available tools. You do not need to deploy backend source, provide a Cloudflare API token to NL-Veil, or configure individual tools. Garrett's dashboard handles any Cloudflare account setup needed for the deployment.

The key is encrypted with the local server's key and bound to your NL-Veil user account. It is never returned by the status API or saved in desktop preferences. An invalid replacement key leaves the previous connection intact. Existing legacy connections remain usable until you choose to replace or disconnect them.

Trial includes MCP and backend API access. Autonomous website protection, identity monitoring, follow-up, and email alerts require paid Agent or an eligible admin-granted plan. Those dashboard services continue while NL-Veil is closed.

Choose which feature receives the toolset:

| Feature | Enable it | Change it later |
| --- | --- | --- |
| Chat | Enabled after connecting; click **Agent Garrett: on/off** beside auto-loop | Click the same label to switch it off |
| Swarm | Check **Agent Garrett** in the deploy form | The choice applies to that deployed swarm |
| Tater-tot | Check **Agent Garrett** in the deploy form | Send `/garrett on` or `/garrett off` |
| CLI chat | Run `veil chat --garrett` | Start a chat without that flag |

Tools appear individually as `security_<upstream_name>`, with typed argument schemas. For example, `security_gary_bash` accepts a command, a boolean background flag and a numeric timeout. `garrett_tools` lists the current catalogue with schemas; `garrett` remains a compatibility wrapper accepting a tool name and an argument object. The available catalogue is discovered from your authenticated service rather than a hard-coded tool count.

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

## Lab and red-team work

The same runtime can inventory an authorized lab, run selected checks, preserve findings and traffic, and organize retests. Give it an explicit target set, a goal and the expected evidence. For example: “Inventory the services in my supplied lab scope, save the results, identify candidate weaknesses and propose the next verification step.” For a retest: “Use the saved finding and its traffic to verify whether my fix changed the observed behavior, then record the result.”

The deployment enables active and Gary tools. Its tool catalogue is not a statement that every command has been exercised against every target. Choose the actions appropriate to the environment you are testing, and inspect the resulting evidence in NL-Veil.

## Verify the connection

Turn Agent Garrett on in chat and ask: “Call `security_gary_bash` with `printf 'hello from Gary\n'; uname -s`, then show the exact output.” The command should run in the cloud Container and report `Linux`. Use `security_gary_shell_list` to inspect cloud shell sessions. `security_ioc_extract` can be checked with a synthetic domain and documentation address without contacting a target.

MCP credentials stay on the NL-Veil server for desktop and CLI chat calls. Each request carries your Garrett Bearer API key. Existing cloud tater-tots receive the connection through Cloudflare secrets; a failed sync is shown in Settings and retried when their runtime is next mirrored. Their per-tot opt-in stays unchanged.

**Open live agent logs** takes you to Garrett's dashboard activity view. **Disconnect from Veil** disables the local connection and clears its tater-tot pointers when Cloudflare is available. It does not delete the cloud agent, cancel billing, revoke the dashboard API key, or erase memory. If cloud sync is pending, reconnect Cloudflare or revoke the key in Garrett to stop cloud use immediately. Manage agent deletion, key revocation, billing, and protection settings in Garrett's dashboard.

## Licenses and corresponding source

NL-Veil code uses its [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.12/LICENSE). Legacy v1.1.12 self-hosted Gary bundles include modified [ARTEX](https://github.com/Hinln/ARTEX) source under [AGPL-3.0](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-LICENSE). The [Gary notice](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-NOTICE), [source archive](https://github.com/gary23w/nl-veil/raw/refs/tags/v1.1.12/cloud/gary-source.tar.gz), and [Cloudflare build sources](https://github.com/gary23w/nl-veil/tree/v1.1.12/cloud) remain available with that historical release. Current dashboard onboarding connects to the managed service. Dependencies retain their own licenses.

## Tater-tot schema discovery

Tater-tots see every available Garrett tool during planning. Before using a `security_*` tool, they call `tool_schema` with its exposed name to obtain the complete input schema. Arrays, nested objects, booleans and numbers retain their original types. This avoids sending all 166 schemas in every model request. The tater-tot must have Agent Garrett enabled and its deployment connection ready.
