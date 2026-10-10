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
