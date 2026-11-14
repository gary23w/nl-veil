# the veil v1.1.31

The veil in your browser, and every veil of your account on one harness. The web chat runs in a browser tab on your own Cloudflare account, through a harness Worker that lives in that account. The desktop app and the local web app now use that same harness: they read its jobs, schedules and chats, can deploy it for you, and join the account's mesh so that a task can be sent to one of your machines.

## What changed

### The desktop app and the server

- **The web harness, from the desk.** When you are logged in to Cloudflare, the server finds your `veil-web` harness through your account's workers.dev subdomain and calls it with the login it already holds. The desk's **Tasks** tab has a **Web harness** view, and the local web app's Tasks page a matching section: queue a job, read its result, cancel it, see the harness's schedules, open one of its chats as a transcript, and send the open conversation up to it.
- **Deploy my runtime.** A user with no harness no longer has to go to the website for one. **Deploy my runtime** (the Web harness view and the local web app's Tasks page, or `POST /api/v1/harness/deploy`) puts the harness that ships inside this build into your own Cloudflare account with your login. It only happens when you ask.
- **The mesh.** Every veil logged in to one account tells its harness it is there: desks, servers and open web chat tabs. The Web harness view lists them and sends a task to one machine; only that machine is handed it. A desktop veil runs work sent to it only after its owner turns that on, and the setting stays on that machine. Shared settings, such as the model choice and the theme, are kept level across your veils.
- **Matrix takes the blog's palette** on the desk and in the local web app: the same sixteen colours as the site and the web chat. A `matrix.lua` you have changed is left as it is.
- **A Web chat button** at the right end of the desk's tab bar opens the web chat.
- **The desk's right pane keeps its tab row inside the pane.** Activity, Tasks and Memory no longer run under the collapse arrow in a narrow pane or with a wide face.
- **Fresh Cloudflare logins work again.** Cloudflare retired the `workers-scripts.bind` scope, and its login page refused any login that still asked for it. The veil no longer asks.
- **The Cloudflare login result page carries the veil's icon.**

### The web chat

The web chat is a page of the site, not part of the downloads below. It needs no install: log in with Cloudflare, deploy the harness into your account once, and chat. Nothing of ours sits between the page and Cloudflare.

- **A workspace and an editor.** Files the chat writes open in a Code tab with a live preview. The editor holds long files and suggests as you type; a comment that asks for code becomes code with Ctrl+Enter. A folder on your disk, or a repository cloned by its address, can be the workspace, with commit, pull and push. A terminal under the editor runs a small shell over the workspace, Python and JavaScript.
- **The harness does what a tab cannot.** It calls Workers AI, reads and searches the web, runs Python, and keeps your chats so that they follow your login to any browser. Long or repeating work runs there as jobs and schedules with the tab closed, and swarms work toward a goal on their own, round by round.
- **Pictures.** An Images tab lists your account's image models with the settings each one takes: size, steps, guidance, seed, a negative prompt, a picture to start from, a mask, reference pictures. Left to choose, the harness picks the best working model your account has for the job and moves on to the next when one fails. Pictures are kept in your browser, and a downloaded PNG carries its prompt and settings. The chat can make, change and read pictures, and `/imagine` goes straight to the image model.
- **Films.** A Video tab turns an idea into a storyboard, or takes frames you already have. Each shot is made of many pictures, each made from the one before. The harness looks at each new frame, writes the prompt for the next from what is in it, and has Clef or a vision model confirm the frame follows before it is kept. A renderer compiled into the page (`veil_core.wasm`) finds the motion between frames and draws the frames between them. Narration comes from your account's speech models, and the film is written as an MP4 in the browser.
- **The chat drives the studio.** Through its tools the chat works the Images and Video tabs and swarms: the gallery and the picture queue, editing, making and rendering films, and pausing, resuming, re-aiming or deleting a swarm. Deleting a picture or a film asks you first. Queued jobs, swarm minds and MCP callers can make pictures and plan films in the harness, and what they make arrives in the page's gallery and film list.
- **Clef in the browser.** The web chat reviews its answers with Clef as the desktop does, and checks that a turn did what it was asked before it answers.
- **Your veil as an MCP server.** Other AI tools can connect to your harness with a key made in the Harness tab, and use its tools.
- **Agent Garrett and MCP servers** can be connected in the Harness tab, and their tools are on the chat's belt.
- **The browser link** (the extension in `extension/`, version 0.2.1) can drive a tab of your own browser for the web chat, once you allow it in the extension's popup.

## Verification

`scripts/check.ps1 -Full` passed on Windows (the server build, the default build, the server and desk test suites, the Linux compile of the tests, the tater tots runtime and Python runner), and `scripts/check.sh --full` passes in CI on Linux before any bundle is built. Every bundle on this page passed the release workflow's processor check, the macOS minimum check where it applies, and the packaged-app smoke test on its build machine before it was attached. The harness's own tests and the renderer's tests run under node.

Run against the real services: the web chat's login, chat, Python, Clef and web reading on a deployed harness; pictures from every image model the account listed; speech in English and Spanish; a narrated film rendered to MP4; a frame directed and confirmed by Clef, and by a vision model in Clef's place. Not run against the real services: the mesh sending work to a desktop veil, a schedule firing on its own, and a Python harness on an account without the Workers Paid plan. Film frames made from one another still change in fine detail from frame to frame, which can show as shimmer.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.31-windows-x86_64.zip` |
| Windows x86-64 with AVX2 | `veil-v1.1.31-windows-x86_64-avx2.zip` |
| Linux x86-64 | `veil-v1.1.31-linux-x86_64.zip` |
| Linux x86-64 with AVX2 | `veil-v1.1.31-linux-x86_64-avx2.zip` |
| macOS Apple Silicon | `veil-v1.1.31-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.31-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately. Everything in [v1.1.30](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.30.md) is included.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.30...v1.1.31) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.31/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
