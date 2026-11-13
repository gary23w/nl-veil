# the veil v1.1.30

Clef mode, and Agent Garrett as the veil's own tools. A chat turn spends model calls on decisions that are a yes or a no. For anyone logged in to Cloudflare, those decisions now go first to Clef, Cloudflare's decision model on Workers AI, which answers with a probability instead of text. Agent Garrett's tools are presented to the model as built-in tools, and a clipboard without text no longer closes the desktop app.

## What changed

- **Clef mode.** Three decisions of a server-side chat turn are put to `@cf/cloudflare/clef-flash` before a chat model sees them:
  - *Plan reconcile:* after a work step, one yes/no question per remaining plan task, all in one call. Clef's answer replaces the chat model's call.
  - *Course check:* "should the next step proceed?" A confident yes lets it proceed with no reviewer call.
  - *Answer review:* "does the answer contain a material problem?" A confident no is silence with no review call.

  A probability of 0.85 or more is a yes and 0.15 or less is a no. Anything between, and any failed call, goes to the chat model exactly as before, so a Clef call can save a model call but never decides alone when it is unsure. Only a model writes text: a replacement step or a correction still comes from the chat model.
- **On by default, for Cloudflare logins only.** Clef runs on the user's own Cloudflare login, so a turn of a user who is not logged in is unchanged, and logging in is what turns it on. To turn it off: the desk's **clef mode** toggle (Settings, below the tool map), the admin's **Clef mode** box in the web app's server configuration, `"clef": false` on a message, or `NL_CLEF=0` before the first start. `veil chat --clef` asks for it on a server whose default is off.
- **Each Clef call is on the event stream.** It writes an `llm` frame labelled `clef-planrec`, `clef-course` or `clef-reflect` with the model, the time and the input tokens, beside the frames of the calls it stands in for. The per-model usage lines do not count Clef calls yet.
- **Agent Garrett reads as built-in tools.** The two wrapper verbs no longer describe the tools as reached "over MCP", and tell the model not to look for them with `mcp_discover` or `mcp_call`. An `mcp_call` that names Agent Garrett as its server now runs as the built-in tool on the server, instead of searching the machine's MCP configuration files and answering "server not found".
- **`garrett_tools` answers "what do I have".** It is on the belt whenever Agent Garrett is, including beside the catalogue's own `security_<name>` tools. It returns how many tools there are and one line for each; asked for one tool by name, it returns that tool's full input schema. The plain list no longer carries every tool's schema.
- **A clipboard without text no longer closes the desk.** When the clipboard was empty, held an image or files, or was held open by another program, the Agent Garrett card's **Paste key / MCP config** button and Ctrl+V in a text field read a missing string and the app closed. Both now read it as empty.
- **Reasoning is shown once.** Some providers send one reasoning fragment under two names; the stream reader typed each fragment twice. It now takes it once.
- **neuron-db v0.4.0.** The cloud store build and binding are v0.4.0. A single-value memory write now clears its scope and stores the value under the scope's own key. A neuron binary without that operation is asked once per process and then written to as before.
- **Chat recall prefers the newer fact on an exact tie.** When two recalled facts score exactly the same, the newer one is listed first, so a corrected fact is not listed under the one it replaced.

## Verification

`scripts/check.ps1` passed on Windows (the server build, the default build, the server and desk test suites, and the Linux compile of the tests), and `scripts/check.sh --full` passed in CI on Linux. Every bundle on this page passed the release workflow's processor check, the macOS minimum check where it applies, and the packaged-app smoke test on its build machine before it was attached.

Run against the real services on Windows: an answer review went to Clef and came back with a usable probability, and `garrett_tools` listed a connected agent's tools. Not run against the real services: Clef's plan reconcile and course check, which are covered by tests of the request and reply only. The clipboard fix is covered by a test of the missing-string case; the button was not clicked again with a non-text clipboard. How often Clef is confident enough to save a call has not been measured.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.30-windows-x86_64.zip` |
| Windows x86-64 with AVX2 | `veil-v1.1.30-windows-x86_64-avx2.zip` |
| Linux x86-64 | `veil-v1.1.30-linux-x86_64.zip` |
| Linux x86-64 with AVX2 | `veil-v1.1.30-linux-x86_64-avx2.zip` |
| macOS Apple Silicon | `veil-v1.1.30-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.30-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately. Everything in [v1.1.29](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.29.md) is included.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.29...v1.1.30) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.30/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
