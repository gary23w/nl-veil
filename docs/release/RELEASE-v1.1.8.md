# the veil — v1.1.8

Tater-tots can improve their shared Worker runtime and continue through browser challenges. This release also protects the admin account before the HTTP listener or Cloudflare Tunnel starts.

## What changed

### Tater-tots

- Tots can read, edit and deploy the JavaScript behind their shared runtime, including prompts, tools and stop rules. These tools are available without the local execution grant.
- Runtime drafts are stored in the account's shared Durable Object. Revision checks prevent concurrent edits from overwriting each other, and deployment results return to the tot.
- Your running, Cloudflare-connected veil uploads requested revisions using your existing login. Cloud work continues on the last deployed runtime while veil is offline. Failed uploads preserve the live version, and saved runtime edits survive restarts and normal runtime upgrades.
- Browser tasks can work through CAPTCHA challenges with the existing browser tools and verify the result. A search that encounters a challenge keeps the page open so the tot can act on it and continue; detection no longer forces a human handoff.

### Admin login

- A fresh or existing admin account cannot keep the published legacy default password. Startup replaces it even when the server binds only to loopback, because a Tunnel can still expose that listener.
- An explicitly configured `NL_ADMIN_PASSWORD` now applies to existing admin accounts. An existing custom password is preserved when no replacement is configured.
- Startup verifies that the admin identity and password hash were saved and read back before opening the listener. If a required update or storage verification fails, startup stops. A failed replacement does not overwrite the old in-memory password hash or sessions.
- A stale generated-password file cannot restore an older credential or apply a password to a different admin email.

Review your admin password after updating. Set a strong `NL_ADMIN_PASSWORD` if you manage the server through the environment. Keep the Tunnel off until the updated app has started successfully and you have verified admin login.

## Verification

The source fix passed the full local `scripts/check.ps1 -Full` gate with the Neuron storage executable present. The tests include legacy-password rotation, persisted readback, configured-password reconciliation, and fail-closed startup when storage verification fails. Pull request [#5](https://github.com/gary23w/nl-veil/pull/5) passed its CI check and GitGuardian check before merging. This note describes source verification; packaged first-boot and Tunnel checks must be completed against the v1.1.8 bundles before publication.

The tot changes passed 45 JavaScript tests and 872 native tests, with one native test skipped, plus a server build. Coverage includes completing a simulated browser challenge, concurrent runtime edits, deployment failure, account separation and preservation of deployed source. The release workflow checks the merged source and exercises the packaged app and Cloudflare transports on Windows, Linux and both macOS architectures before publishing.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a first installation, download the full v1.1.8 bundle for your platform from the [release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.8), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep the complete bundle together, including `veil-install.txt` and `bin/neuron`, and preserve your existing data directory.

The bundles remain unsigned. Update verification and recovery are described in the [update guide](../UPDATES.md).
