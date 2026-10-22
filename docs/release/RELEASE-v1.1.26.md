# the veil v1.1.26

This release is about fresh machines: the Cloudflare login completes again, the desktop puts its tray icon where you can see it on the first run, and a computer without Python no longer leaves the agent unable to run anything. The desktop chat gains a scrollbar and a Tasks tab where a running program can be watched and cancelled, and the programs the veil starts for model calls, memory, git and its tools now run under a deadline.

## Fresh machines

- **Cloudflare login on a new machine.** Signing in from a machine that had never connected ended on Cloudflare's page with `invalid_scope`. The login asked for two permissions, `containers.read` and `containers.write`, that the veil's OAuth client was never granted, and Cloudflare refuses the whole request when one scope is not allowed. Nothing used them; they are gone from the request. A machine that was already connected kept working because it never asked for consent again. When Cloudflare refuses a login for any reason, the page now shows Cloudflare's own explanation, and for a scope refusal it says the fix is on the veil's side.
- **The tray icon on Windows 11.** Windows 11 puts a newly added tray icon in the hidden overflow area until the per-icon setting under `HKCU\Control Panel\NotifyIconSettings` says otherwise. On the first run the desk now promotes its own icon once, if you have not chosen a setting for it yourself, and re-adds it so it shows. An icon you hid in Settings stays hidden. The desk also retries adding the icon when the shell answers too slowly at startup.
- **Machines without Python.** The agent has two new tools. `run_shell` runs a PowerShell, bash, sh or cmd script in the workspace, with the same time cap and result shape as `run_python`. `tool_env` keeps an environment change for every later tool run: `refresh_path` re-reads the machine's PATH after an installer changed it, and `set NL_PYTHON_BIN=<path>` names an interpreter directly. So when Python is missing, the agent installs it with `winget`, `brew` or `apt`, refreshes the path and carries on, with no restart. The setting is kept in `tool-env.json` beside your data. `NL_PYTHON_BIN` is now honoured everywhere the veil starts Python. Small local models get both tools too.

## The desktop chat

- **A scrollbar.** The conversation and the Chats list have a light, translucent scrollbar you can drag or click, for anyone without a scroll wheel. PageUp and PageDown page the conversation, and Home and End jump to either end while the message box is not focused.
- **Tasks.** A program the veil starts on your machine for a chat — a wait, a build, a script — is listed in the new **Tasks** tab of the right pane while it runs, with what it is doing, how long it has run, and a **Cancel**. Cancel ends that one program and the chat goes on; the model is told you stopped it. The status line under the chat has its own cancel for the program running now.
- **Stopping a wait.** **Stop** now also ends the program running on your machine for that turn. Before, a `poll` kept running to its own limit after Stop, and its timer stayed on screen. A message you send while the veil is waiting ends the wait at once so it can read your message, and a short "stop that" cancels the running program.
- **Tool map toggle.** Settings → General → Behavior has a saved **tool map** switch below reasoning. It is sent with each server chat message and wins over `NL_TOOL_MAP`.

## Reliability

- **Child processes are bounded.** The model calls, neuron-db, git, the swarm's checks and most tools now run their child processes under one deadline each. Before, on Windows, a child that printed nothing never timed out, and one that kept printing past its output limit could stop the caller indefinitely.
- **Long output.** A swarm's verification check, a dependency install, a `run_python` script and the desktop's git commands that print a lot now run to their own exit and keep the start and end of what they printed. Before, a verification check or install was stopped at the output cap, so a verbose passing test run was scored as a failure and a chatty `npm install` was killed mid-install.
- **Downloads and crawls.** The tunnel connector downloads to a temporary file that replaces the real one only when it is complete, so an interrupted download no longer leaves a broken `cloudflared` behind. A deep crawl stops at its own time budget and returns what it found.
- **Chat memory.** Recall in a chat now asks neuron-db for the breadth it means; before, every chat recall ran at neuron-db's default. Two chats writing memory at the same moment no longer lose each other's writes: writes to one store wait their turn and retry while another process holds it. `NL_MEM_K` and `NL_MEM_HOPS` override the recall breadth.
- **Reading instructions.** "Do not read or create any file" no longer makes the veil write a plan, and a sub-chat goal quoted inside a message no longer stops the main chat from using its own tools.
- **Accounts and sessions.** Sessions are tied to the account and to its revocation state, so a password change, a ban or a re-created account ends every older session; the server enforces session age on every request; a deleted account's API key or data can never pass to a new account; and startup refuses to run on an account store it cannot read completely.
- **Usage metering.** Metered runs keep a per-run usage checkpoint, admin top-ups carry an idempotency ID so a retried request is not counted twice, and deleting a running metered swarm first stops it and settles its final usage.

## Off by default: chats that see each other

A chat and its sub-chats can now share what they know, behind four settings that are all off unless you set them before starting the server: `NL_FAMILY_VIEW` (a family view and finish notices in the desktop), `NL_FAMILY_STATUS` (each sub-chat's true status), `NL_FAMILY_NET` (each member's work in the others' context) and `NL_FAMILY_MSG` (messages between a chat and its sub-chats). With all four unset nothing changes. See [the family overlay](https://github.com/gary23w/nl-veil/blob/main/docs/docs-src/worker/chat/family.md).

## After updating

- If you use the web app, sign in once more. Sessions stored by earlier versions are signed out on the first start, so they cannot outlive a password change. The desktop app and the `veil` command line are not affected.
- Nothing else to do.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release tree: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build. The server test suite ran 1,117 tests with one platform skip, and the desktop suite 337.

Not yet seen working outside the tests: the tray icon's promotion on a fresh Windows 11 machine, a Cloudflare login from a machine that never connected, the desktop's scrollbar and Tasks tab in a running desktop, `run_shell` on macOS and Linux, and the chat family settings with a real model.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.26-windows-x86_64.zip` |
| Linux x86-64 | `veil-v1.1.26-linux-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.26-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.26-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.25...v1.1.26) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.26/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
