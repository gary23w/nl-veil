# the veil v1.1.9

Every tater-tot deployment now has its own console and run history. Deleting Gary and deploying Gary again no longer leaves the new run showing the old console or waiting for its event sequence to catch up.

## What changed

- The desktop selects a deployment by its name and run folder. A new deployment starts a fresh console; an existing run keeps its console when it ends.
- **Past runs** lists retained deployments below the live tots. Ended runs read their events from their local folder, and **Deploy again** opens the deployment form with the previous request.
- Failed deployments are saved with the requested goal, model and failure details. The desktop opens the failed run so the error remains available after the toast disappears.
- Deleting a tot syncs its events one last time and marks its saved run as deleted.
- New authenticated run-history endpoints list saved runs and read their events. A lifetime bug in the failed-run recorder was fixed so the returned run name remains valid.

## Verification

The source changes in `fdb4040` passed the repository's [full CI acceptance check](https://github.com/gary23w/nl-veil/actions/runs/37050609123). Tests cover run parsing, redeployment selection, failed-run records, retained events and route authentication. The release workflow checks the versioned source and runs packaged-app and Cloudflare transport smoke checks on Windows, Linux and both macOS architectures before publication.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a first installation, download the full bundle for your platform from the [v1.1.9 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.9), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Keep the complete bundle together and preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.8...v1.1.9) · [Update and recovery guide](../UPDATES.md)
