# the veil v1.1.21

A veil that starts while another one holds its port now comes up anyway. Before this release, its window opened onto "server down", and Settings showed "checking the server..." under the Cloudflare login and the built-in model with no way out. This release also adds a Cloudflare default to Settings, and points Windows users at the Microsoft Store.

## What changed

- **A taken port no longer leaves the app without a server.** On 2026-10-16 a v1.1.20 bundle was started while another install's veil sat in the tray holding port 8787. Its built-in server never started, nothing retried, and its window stayed disconnected. Now the app waits up to four seconds for its port, which covers a veil that is still quitting, then takes the next free one. Its window, the Cloudflare login's return address and everything else follow the port it actually got. A server started with `--server-only` keeps its configured port and still says plainly when it is taken.
- **The Cloudflare login says when it cannot finish.** Cloudflare's login returns to port 8787 only. A veil that had to move shows why on its login row ("quit the other one and restart this veil to log in") instead of a button that ends on Cloudflare's error page. A Workers AI API token works on any port.
- **A visible message when the server cannot start at all.** A double-clicked veil has no console, so on Windows a message box now names the port and what to do.
- **The Cloudflare default.** Settings › Models has three boxes: **Use server chat**, **Use one model for every role** for a custom setup, and **Use Cloudflare Workers AI (default)**. With the Cloudflare default on, the chat runs on your Cloudflare login with one Workers AI model for every role, and the page shows only the model dropdown and the login. Logging in with Cloudflare turns it on, and a chat that already runs on Workers AI as one model starts with it on. Turning it off brings back the provider, account, key and per-role fields.
- **Windows: the Microsoft Store.** nl-veil is on the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). The Store version is signed by Microsoft and installs with no SmartScreen prompt. The zip from this page is still unsigned and shows "Unknown publisher"; the bundle script can now sign the Windows binaries before they are packaged, once a signing certificate is set up.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release commit: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build.

New tests cover the port choice against real listeners (a free port is kept, a port let go of within the wait is kept, a port held throughout is left for the next free one), the lock record following the port, the Cloudflare status and login refusal on a moved port, the Cloudflare default's on, off and undecided states, and its persistence. The signing hook was exercised with a stand-in signer: both binaries are signed before packaging, nothing runs when it is unset, and a failing signer stops the build.

Not yet verified on screen: the new Settings layout and the moved-port message in a running desktop.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). For a new installation, download the complete bundle from the [v1.1.21 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.21), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.20...v1.1.21) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code is licensed under MIT. The Gary security runtime is licensed under AGPL-3.0. Its source archive and Cloudflare build sources are available in the repository and included in full release bundles. Dependencies retain their own licenses.
