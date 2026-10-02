# the veil — v1.1.8

This security release includes the v1.1.7 features and protects the admin account before the HTTP listener or Cloudflare Tunnel starts.

## What changed

- A fresh or existing admin account cannot keep the published legacy default password. Startup replaces it even when the server binds only to loopback, because a Tunnel can still expose that listener.
- An explicitly configured `NL_ADMIN_PASSWORD` now applies to existing admin accounts. An existing custom password is preserved when no replacement is configured.
- Startup verifies that the admin identity and password hash were saved and read back before opening the listener. If a required update or storage verification fails, startup stops. A failed replacement does not overwrite the old in-memory password hash or sessions.
- A stale generated-password file cannot restore an older credential or apply a password to a different admin email.

Review your admin password after updating. Set a strong `NL_ADMIN_PASSWORD` if you manage the server through the environment. Keep the Tunnel off until the updated app has started successfully and you have verified admin login.

## Verification

The source fix passed the full local `scripts/check.ps1 -Full` gate with the Neuron storage executable present. The tests include legacy-password rotation, persisted readback, configured-password reconciliation, and fail-closed startup when storage verification fails. Pull request [#5](https://github.com/gary23w/nl-veil/pull/5) passed its CI check and GitGuardian check before merging. This note describes source verification; packaged first-boot and Tunnel checks must be completed against the v1.1.8 bundles before publication.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a first installation, download the full v1.1.8 bundle for your platform from the [release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.8), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep the complete bundle together, including `veil-install.txt` and `bin/neuron`, and preserve your existing data directory.

The bundles remain unsigned. Update verification and recovery are described in the [update guide](../UPDATES.md).
