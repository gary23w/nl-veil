# the veil — v1.1.3

**Update from the desktop, without Git.** Official bundles check GitHub releases in the background when
the app starts. Finish active work, then choose **Settings → App updates → Update & restart**. The app
downloads and verifies the next stable release, replaces both the desktop/server executable and memory
engine, and starts again with your data and configuration intact.

**Install v1.1.3 manually once.** v1.1.2 and earlier do not contain the updater. Extract the complete
bundle into a writable folder and retain `veil-install.txt` and `bin/neuron[.exe]`. When moving an
existing installation, keep your data directory; do not overwrite it with another installation's data.

## Downloads

| Platform | Full desktop bundle |
| --- | --- |
| Windows x86_64 | `veil-v1.1.3-windows-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.3-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.3-macos-x86_64.zip` |
| Linux x86_64 | `veil-v1.1.3-linux-x86_64.zip` |

Run `veil.exe` on Windows or `./veil` on macOS/Linux. The `veil-update-*` assets are for the built-in
updater; the `veil-server-*` assets are headless builds. GitHub's source archives require a compiler.

## What changed

- **Verified native updates.** Exact platform assets, GitHub SHA-256 digests, size limits and a staged
  executable version check prevent partial or mislabeled downloads from replacing the app. No Git,
  Python, Node or archive utility is required on the update path. It uses the OS curl executable.
- **Staged shutdown and recovery.** The compiled helper confirms readiness, waits for the old process,
  verifies both files again, retains backups and restores the old pair after replacement failures.
  The Windows helper survives the app's child-process cleanup. Original launch arguments and working
  directory are retained. Data, models, plugins and credentials are not replaced.
- **Real tunnel readiness.** A quick-tunnel URL alone is no longer treated as a successful connection.
  The app waits for Cloudflare's registered-connection message before proceeding to DNS publication.
- **Actionable connection errors.** Cloudflare Tunnel needs outbound UDP 7844 for QUIC or TCP 7844 for
  HTTP/2. HTTPS 443 access alone is insufficient. Error messages point to the connector log and these
  requirements; no blanket inbound firewall exception is needed.
- **Release gates on each platform.** Native jobs exercise the extracted bundle, version, isolated
  server, shipped update helper, and actual Cloudflare HTTP/2 and QUIC public round trips. Test tunnels
  serve only a random marker. All four platforms must finish before the draft release is published.
- **Current model catalog.** Includes the reviewed model sync adding GLM-5.3-FlashX and updating the
  catalog's display-price metadata.

## Platform approval and limits

These binaries are still unsigned; Authenticode, Apple Developer ID signing and notarization are not
included. Follow your operating system's approval flow for a release you trust. SmartScreen/Gatekeeper
launch approval is separate from firewall policy. Managed devices may require an administrator to allow
the app or the `cloudflared` connector's outbound connections.

The update helper retains backups under `.veil-update-<id>`. Two-file replacement is not atomic against
power loss, and a successful process launch does not detect every subsequent crash. See the
[update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md) before removing backups.
Release smoke tests do not grant OAuth consent or verify account-specific Workers AI, R2 or Access policies.

[v1.1.2 notes](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.2.md)
cover the preceding credential-handling and delivery fixes.
