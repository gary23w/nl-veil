# Desktop release updater

Source: `desk/src/updater.zig`.

The merged desktop configures the updater with its own version and original arguments. Startup checks
GitHub on a worker thread only when the executable lives in a marked official bundle. Settings renders
the atomic phase and offers a user-initiated install. Exact platform assets carry GitHub SHA-256 digests;
both native files are verified before handoff. The copied executable's `--veil-apply-update` entry runs
before server initialization, waits for the old process, replaces both files with rollback, and restarts.

See [Desktop updates and release connectivity](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md) for the packaging contract, recovery,
network requirements and verification limits. Unit tests are explicitly registered in the desk test root.
