# the veil v1.1.10

Deploying a tater-tot now checks that its runtime is reachable and repairs stale setup before creating a run. The desktop gives saved runs more space, keeps activity controls clear of the event rows, and lets you remove old entries from history while preserving their files.

## What changed

- A cached runtime whose Worker, route or token is no longer usable is reconnected once using its saved source. Deployment waits for readiness before sending the create request.
- Enabling the runtime's workers.dev route must succeed. Cloudflare setup errors remain visible instead of becoming a generic request to deploy again.
- Create requests are sent once. A lost reply tells you to refresh live tots before retrying, avoiding duplicate unnamed deployments.
- Past-run cards show the name, state, goal, timestamp and event count on separate lines. Goals and deployment errors wrap in the detail panel, and the activity filter and copy controls sit above the event rows.
- **Remove run** removes a saved entry from the list after a second click. Its status, events and notes remain in the original folder. Removing that folder's `.hidden` marker restores the entry.

## Verification

Server and desktop regression tests cover stale-runtime recovery, refused public routes, avoiding repeated create requests, authenticated history removal, preservation of files and other users' runs, and clearing the removed run's console. The desktop layout was rendered for visual inspection. The reconnect path also restored a missing live Worker and passed an authenticated readiness check while preserving its saved source and revision; no tot was started by that check.

The release workflow runs the full acceptance checks and packaged-app smoke checks on Windows, Linux and both macOS architectures before publication.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a first installation, download the full bundle for your platform from the [v1.1.10 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.10), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep the complete bundle together and preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.9...v1.1.10) · [Update and recovery guide](../UPDATES.md)
