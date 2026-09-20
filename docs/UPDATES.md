# Desktop updates and release connectivity

In v1.1.3, the updater is directly under Settings → App updates. In v1.1.4, use the Updates page.

Starting with v1.1.3, official bundles check the latest stable GitHub release in the background when the desktop starts.
Open **Settings → Updates → App updates → Update & restart** after finishing active work. The app downloads and
verifies both native components, then closes and restarts. Git, Python, Node, archive utilities and
package managers are not required for updates. HTTPS uses the OS `curl` executable (included on
supported Windows/macOS installations; Linux installations need curl).

Install v1.1.4 (or another current full bundle) manually once to acquire the updater. Older versions such as v1.1.2
cannot acquire a feature they do not contain. Keep the complete bundle together, including
`veil-install.txt` and `bin/neuron`, in a writable folder. Development executables and standalone
`veil-desk` installations do not self-update. Updates target stable releases and never downgrade.

## What is installed

Each platform publishes two additional GitHub assets:

```
veil-update-v<VERSION>-<PLATFORM>-app
veil-update-v<VERSION>-<PLATFORM>-neuron
```

The platform is windows-x86_64, macos-arm64, macos-x86_64 or linux-x86_64. The updater requires exact
asset names and repository URLs, bounded positive sizes and GitHub's SHA-256 asset digests. It downloads
both files into a fresh directory beside the app, verifies size and checksum, and executes the staged
app's `--build-version` command to reject a mislabeled or unlaunchable executable. No archives are
extracted on the update path. If a release is still uploading or lacks the native update pair, it cannot
be installed. Missing network access or GitHub rate limiting does not prevent normal startup.

A copy of the current app acts as the helper. It acknowledges readiness before the old app exits, waits
for that process to finish, verifies the staged files again, backs up both old components and replaces
them. On Windows the helper explicitly leaves the application's kill-on-close job; other child processes
remain in that job. Launch arguments, environment and working directory are retained. Only the app and
memory-engine files are replaced; data, credentials, models, plugins and configuration are left in place.

Replacement errors restore the old pair. A failed process launch also attempts restoration and starts
the previous version. This does not detect every crash after a successful process spawn, nor is a
two-file replacement atomic against power loss. Backups are retained in `.veil-update-<id>/old-app`
and `old-neuron`; do not delete them until the new version is working. A failed install writes
`update-error.txt` when possible. If filesystem recovery fails, the helper does not launch a mixed pair.

For recovery, close all copies of veil and its helper, restore both backups to `veil[.exe]` and
`bin/neuron[.exe]`, then remove the empty `.veil-update-lock` directory before retrying. Never copy an
entire old release over your data directory. Interrupted staging may leave its directory for inspection.

## Cloudflare and operating-system approval

Windows normally permits outbound connections. macOS's built-in application firewall primarily governs
incoming connections. A blanket inbound firewall exception for veil is not required for Cloudflare
Tunnel. Cloudflare connections are initiated by the local connector:

| Purpose | Process / destinations | Required outbound access |
| --- | --- | --- |
| Release downloads | curl → api.github.com, github.com and GitHub asset hosts | HTTPS TCP 443 |
| OAuth and account API | browser/curl → dash.cloudflare.com, api.cloudflare.com | HTTPS TCP 443 |
| Tunnel transport | cloudflared → Cloudflare tunnel endpoints | UDP 7844 for QUIC, or TCP 7844 for HTTP/2 |
| OAuth callback | browser → local callback listener | Loopback only |

Corporate endpoint protection, an outbound-deny policy, VPN, router or proxy can still block these
connections. Allow the actual `cloudflared` executable in the network policy, using Cloudflare's
documented destination list. HTTPS 443 access alone does not establish a tunnel. The default connector
protocol can fall back from QUIC to HTTP/2, but HTTP/2 still uses port 7844. Do not disable the firewall,
open inbound router ports, or disable TLS verification to fix this.

The app now waits for `Registered tunnel connection` before treating an assigned quick-tunnel URL as
connected. It then waits for DNS publication. Timeout messages point to `cf_tunnel.log` and the relevant
outbound protocols. A printed hostname alone proves neither transport connectivity nor DNS readiness.

SmartScreen and Gatekeeper are separate from network policy: they can prevent an unsigned downloaded
executable from launching. This change does not add Authenticode signing, Apple Developer ID signing or
notarization, and does not bypass OS protections. Those distribution steps require the maintainer's
signing identities and platform credentials. Follow the OS approval flow only for a release you trust.
CI runners do not reproduce all browser-download quarantine and endpoint-management policies.

Official references:

- [Microsoft: default outbound firewall behavior](https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-firewall/best-practices-configuring)
- [Apple: Firewall settings](https://support.apple.com/en-au/guide/mac-help/mh11783/mac)
- [Cloudflare: required tunnel destinations and ports](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)

## Release verification

The release workflow runs `scripts/smoke-release.py` on each native platform before uploading its
bundle. It extracts into a path with spaces, rejects runtime credentials in the archive, verifies the
app's version, starts an isolated loopback server, runs the shipped update helper against a disposable
installation, and tests Cloudflare HTTPS plus real quick-tunnel round trips using HTTP/2 and QUIC.
The tunnels expose only a random test marker, never the app or its data. Diagnostics are uploaded
separately from release assets; generated runtime credentials are not included.

Maintainer examples (Python 3.12; not an end-user dependency):

```
python scripts/smoke-release.py --bundle bin/veil-v<VERSION>-windows-x86_64.zip --version <VERSION> --cloudflare --output .release-smoke/local
python scripts/smoke-release.py --release v1.1.4 --cloudflare --output .release-smoke/published
```

Each output directory must be new. A connection failure fails the requested check and retains logs;
it is not silently counted as a pass. The smoke test does not grant OAuth consent, create account
resources, or prove R2, Workers AI or custom-domain Access policies work for a particular account.
It also does not automate the desktop update button or native OS approval dialogs.

On 2026-09-19 the published Windows v1.1.2 ZIP passed GitHub digest verification, isolated server startup
and matching health version, Cloudflare HTTPS API access, and public round trips over both HTTP/2 and
QUIC from the development machine. macOS native results require running the updated release workflow.

The final Windows build also passed the full `scripts/check.ps1 -Full` oracle, the updater's checksum
and rollback tests, and a local bundle smoke test exercising the shipped helper, parent-exit wait,
replacement of both binaries, backup preservation and relaunch. All updater runtime paths compile
for Apple Silicon, Intel macOS and Linux; compilation is not a substitute for native execution.
Publication of stable releases is gated on native execution and complete update assets for all four platforms;
see the [release workflow results](https://github.com/gary23w/nl-veil/actions/workflows/release.yml).
