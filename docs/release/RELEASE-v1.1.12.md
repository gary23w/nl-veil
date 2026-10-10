# the veil v1.1.12

Agent Garrett now brings its full 166-tool security catalogue into NL-Veil. Chats, swarm minds and tater-tots receive individual tools with their original argument schemas. Deploying security tools provisions the edge Worker, private execution Worker, dedicated Cloudflare Container and R2 storage in the owner's Cloudflare account. The desktop adds build progress and restores separate feature opt-ins.

## What changed

- **The complete security catalogue.** The deployment enables 94 existing security tools and 72 Gary tools. NL-Veil advertises each as `security_<name>` and preserves nested arguments, arrays, booleans and numeric values. The `garrett_tools` and `garrett` wrappers remain available for discovery and compatibility.
- **Dedicated cloud execution.** Linux commands, files, task orchestration and browser dependencies run in Cloudflare Containers. The first use builds and snapshots the runtime in Cloudflare; no Docker installation or third Linux machine is required. Interrupted builds get a bounded retry and reuse downloaded dependencies.
- **Feature opt-ins.** Chat has a clickable **Agent Garrett: on/off** label beside auto-loop. Swarm and tater-tot deployment forms have their own **Agent Garrett** checkbox. A tater-tot can change it later with `/garrett on` or `/garrett off`; the CLI supports `veil chat --garrett` and tater-tot `--garrett`.
- **Visible preparation.** The Settings security-tools button displays an animated loading bar during upload and while the cloud runtime builds. Its status comes from the authenticated MCP runtime-status method. Completion clears the loading state.
- **Cleaner desktop spacing.** Tab content uses consistent margins, form labels reserve their actual text height, and controls center scaled text. Panel outlines sit inside their clipping area, repairing the missing edges on past-run cards and Settings fields. Settings remains scrollable with its scrollbar hidden.
- **Complete execution teardown.** Remove stops the security Container and deletes both execution Workers before clearing local deployment state. A failed removal keeps enough state for a retry. R2 source and snapshots remain available for recovery.

## Verification

The local release acceptance checks cover model-catalog synchronization, web asset parsing, the cloud tater-tot suite, the Python runner, native server tests, Linux test compilation, desktop tests and the shipped GUI build. Focused regression tests cover typed MCP discovery and dispatch, per-feature opt-ins, deployment configuration, runtime status, and removal ordering and failure recovery.

A live NL-Veil chat reached the deployed Cloudflare runtime through MCP. `security_gary_bash` printed the requested marker and `Linux`; `security_gary_shell_list` returned an empty session list; `security_ioc_extract` extracted and defanged the synthetic domain and address. Those warm tool calls took 290 ms, 592 ms and 139 ms respectively. A second chat completed with the exact cloud command output after the desktop restarted. These timings measure the tool calls, excluding model response time.

The release workflow runs acceptance checks and packaged-app smoke checks on Windows, Linux, Apple Silicon and Intel macOS before publishing all four bundles.

## Use the security tools

1. Open **Settings → Models**, connect Cloudflare, and choose **Deploy security tools**. Existing Cloudflare logins need to reconnect once to grant the new Containers permissions. The account must have Containers and R2 available.
2. Allow the cloud runtime to finish building. The loading bar shows preparation; it is not a percentage estimate.
3. Enable **Agent Garrett** for the chat, swarm or tater-tot that should use it. In a chat, ask: “Use `security_gary_bash` to print `hello from Gary`, then report the actual output.”

[Security tools guide](https://gary23w.github.io/nl-veil/#doc=guide/security-tools) explains the deployment, local-harness boundary and personal defense workflows. Active and Gary tools are enabled in this deployment; choose the intended targets and actions when giving it work. MCP authentication and per-user credential ownership remain in place.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a new installation, download the complete bundle from the [v1.1.12 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.12), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.11...v1.1.12) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code uses its [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.12/LICENSE). Gary includes modified [ARTEX](https://github.com/Hinln/ARTEX) source under [AGPL-3.0](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-LICENSE). The [Gary notice](https://github.com/gary23w/nl-veil/blob/v1.1.12/cloud/GARY-NOTICE), [source archive](https://github.com/gary23w/nl-veil/raw/refs/tags/v1.1.12/cloud/gary-source.tar.gz), and [Cloudflare build sources](https://github.com/gary23w/nl-veil/tree/v1.1.12/cloud) are public and included in every full release bundle. Dependencies retain their own licenses.
