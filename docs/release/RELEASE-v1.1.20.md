# the veil v1.1.20

Tater-tots are **Taters** now, and they run the v1.1.16 algorithms in the cloud. A belt of hundreds of tools is a map they walk, a long step is folded by Gary's 4tope instead of cut, and each model's quirks are learned and healed as they show up. Agent Garrett connects through its managed dashboard. Hosted reasoning models get defaults that adapt to them, and one data directory is served by one veil at a time.

v1.1.17 and v1.1.18 were withdrawn before publication. This release builds on v1.1.16.

## What changed

### Taters

- **The Taters tab.** The desktop's Tater-tots tab is called Taters. Commands, routes and folders keep their names: `veil --tater`, `/api/v1/tots`, `_tots`.
- **The tool tree runs in the cloud.** Past 48 tools, which is a tater with Agent Garrett's catalogue, the built-in belt stays listed and the rest becomes a map. One verb, `open_tools`, shows families and groups, and a group that opens joins the tools by name. A tool called by name opens its own group. The step's own words open the best group before the first call, the open set carries to the next iteration, and the words that led to a tool are learned, so the right group opens first next time. The plan still sees every catalogue tool by name, grouped by what it is for. `/belt auto|map|flat` chooses; `map` walks everything but a small core, for a small model.
- **Gary's 4tope in the cloud.** When a step's messages outgrow the model's window, the oldest rounds are no longer simply cut. The earlier rounds become one net laid out from where the step stands: NEXT, ON DISK, RULED OUT, ESTABLISHED, every line verbatim from a tool result, with no model call. The results the step rests on stay whole. The same net is carried into the next iteration's prompt.
- **Healing, learned per model.** A model that answers only with three times the room is asked for that room first. One that answers nothing three times in a day hands the rest of the day to the fallback model and is tried again the next day; the tater's model setting is untouched. A context-length error halves that model's window and retries once. A model the account lacks routes to the fallback. Nothing here names a vendor: every rule is learned from what a model does.
- **A runtime edit can always be undone.** The last deployed runtime source is kept. A revision that fails to deploy reaches the next iteration as a directive, and the new `runtime_revert` tool restores the deployed source as a new revision.
- **New runtimes reach running accounts.** Once tater-tots owned their runtime, a newer veil could never replace it. The server now offers its runtime as the next revision when the account runs a deployed runtime the veil itself wrote. A tater's own edit, draft or upload is never replaced. Updating to v1.1.20 delivers runtime 11 this way on the first sync, and a tater can read it or revert it like any revision.
- **Agent Garrett by either name.** The `garrett` wrapper takes a tool's belt name (`security_crtsh_subs`) as well as the agent's own (`crtsh_subs`). A name the catalogue lacks is answered with the nearest real names and never reaches the agent, and `garrett_tools` lists the catalogue by branch on one screen.
- **Fewer wasted iterations.** A step that repeats an earlier one is asked once more for a changed method, and a lesson that says the same thing in other words is not kept twice. A failing fallback model is named in the error instead of reading as silence.
- **The console shows the algorithms at work.** A pick event says whether the tool map was in play and how much net it carried, and a fold writes its own status line.

### Agent Garrett

- **A dashboard-managed connection.** Settings has an Agent Garrett page. It opens the Garrett dashboard, where you sign in, choose a plan and deploy your agent. Paste the generated API key or the dashboard's MCP configuration back into NL-Veil, which verifies it through authenticated MCP and discovers the tools. Keys are stored encrypted for the signed-in user. An invalid replacement keeps the working connection, and an existing connection keeps working until it is replaced. Tater-tots receive the connection through their existing secrets.

### The engine on hosted reasoning models

- **The reasoning-effort dial learns.** With `NL_REASONING_EFFORT` unset, a model whose reasoning has overrun a call's bounds is sent `reasoning_effort: low` from then on; a model whose reasoning fits is left at its provider's default. The lesson is saved with the other provider quirks.
- **A starved survey ends planning.** When the survey pass runs out of room while reasoning, the plan pass is skipped for that turn instead of starving the same way.
- **A setting that only shortens reasoning is kept.** When nothing silences a model's reasoning, a setting that cuts it to a quarter or less is sent on auxiliary calls, and dropped if the reasoning grows back.
- **Model calls report what happened.** A starved call is resent with a bigger budget only when it can still finish in time. A stream cut before its end is marked incomplete and metered. No request starts after Stop. A Cloudflare key refreshed after a 401 serves the rest of the turn, and a swarm cast mid-turn deploys with it.
- **A cut reply goes to the step picker**, and Stop is never recorded as a failure. `NL_CHAT_PLAN=0` turns the survey and plan passes off.
- **`run_python` waits up to 120 seconds by default** (`NL_PYRUN_TIMEOUT_S`, at most 240) and says by name when it hit the cap.
- **Edits say what they broke.** `edit_file` notes a definition or import it removed that the file still uses, and refuses an anchor that spans several lines.
- **Continuation and compaction.** The 4tope carry's NEXT keeps the model's last stated intention when the frontier is a bare tool call, and ON DISK names the turn's own changes and counts the rest. Compaction keeps two reads of different parts of a file. The step picker and the course check read the whole request, not only its first paragraph.
- **Recon probes follow the turn's route.** On a client-mode turn they run on the client, like the turn's other tools.
- **Scheduled tasks store no Cloudflare login token.** A Workers AI role with no key of its own rides the login when the task runs.

### Running the veil

- **One server per data directory.** A veil that serves a data directory holds an operating-system lock on it. A second server-only start exits with code 75 and names the holder's process and port. A desktop started on a held directory opens as a client of the running server, on that server's port.
- **Child processes have one real deadline on Windows.** Checks, probes, tool installs and `poll` commands are cut at their bound together with everything they started, even when they print nothing. A `poll` command with quoted arguments now runs on Windows, reports its exit code and output, and ends early when it fails the same way three times.

### Distribution

- **Microsoft Store packaging.** The release workflow builds a Store package of the desktop app and can submit it. The desktop declares DPI awareness, and the repository includes a read-only Store connection check and a reviewer setup guide.
- **Terms.** NL-Veil's responsibility, liability and privacy terms are published on the site.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release commit: model-catalog sync, web assets, the Taters runtime suite (71 tests), the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build.

Taters runtime 11 ran live on a Cloudflare account on 2026-10-15 for 19 iterations. Every pick carried the tool map. The model walked it and called four Agent Garrett tools by name with real DNS and certificate-transparency answers. One step folded seven times and still finished its ten fetches. `glm-5.3-flash` learned to be asked for three times the room, then handed the rest of the day to the fallback model. Deleting the last tater removed its Worker.

Not yet verified live: a real Workers AI error string reaching the model-error classifier, the runtime offer on an account that already runs an older runtime, and the Garrett dashboard flow with a real user key.

## Known issues

- After a fresh runtime upload, a deployment's readiness check can give up after about seven seconds. Deploying again works.
- `veil --tater set --pace` takes effect at the tater's next wake; sending it a message brings that forward.
- A tater's lesson writer can record a rule that does not hold.

## Switches

| variable or command | effect |
|---|---|
| `NL_REASONING_EFFORT` | unset: learn per model (`low` once a model's reasoning overruns); `off` turns the dial off; `low`, `high` or `max` pin a level |
| `NL_CHAT_PLAN` | `0` turns off the survey and plan passes |
| `NL_PYRUN_TIMEOUT_S` | `run_python`'s cap in seconds: 120 by default, at most 240 |
| `/belt auto\|map\|flat` | a tater's belt: `auto` maps what lies past 48 tools, `map` walks all but a small core, `flat` lists everything |

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a new installation, download the complete bundle from the [v1.1.20 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.20), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.16...v1.1.20) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code is licensed under MIT. The Gary security runtime is licensed under AGPL-3.0. Its source archive and Cloudflare build sources are available in the repository and included in full release bundles. Dependencies retain their own licenses.
