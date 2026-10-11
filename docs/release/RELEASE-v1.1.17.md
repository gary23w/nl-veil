# the veil v1.1.17

Lineage refreshes now launch one memory-engine process per lineage instead of nine.
Seven lineages previously launched 63 serialized processes every 30 seconds. They now
launch seven, reducing background work and the delay when loading lineage counts.

## What changed

- The memory engine's new `stats-batch` command opens each database once and returns
  all requested scope counts in order. Existing single-scope commands keep their behavior.
- List and detail requests use one batch for lessons, facts, skills, playbook, rejected
  proposals and the four pending proposal scopes. The API's fields stay the same.
- Zig fills caller-owned count buffers, validates the complete typed response before
  copying results, propagates failures and frees temporary allocations with `defer`.
- CI and every release bundle pin Neuron commit
  `5db2c039bf8f20349299e64650aea2d6a2fce911` on
  [batch/stats](https://github.com/gary23w/neuron-db/tree/batch/stats).
  Packaged-engine verification rejects an older engine without batch support.

Source builds need that Neuron revision too. Build it with the existing release feature
set and supply the resulting binary as `NEURON`, or install it in `bin` before building.

## Verification

`scripts/check.ps1 -Full` passed all nine local acceptance gates, including the server
and desktop suites, Linux test cross-compilation and the full GUI build. Neuron's
native tests, both WebAssembly builds and JavaScript binding batteries passed too.

Regression tests compare batch counts with individual reads, assert nine launches become
one, and assert list and detail routes each launch once per lineage. Parser tests reject
missing, reordered, mismatched, negative and overflowing counts and check every allocation
failure. Neuron CLI tests cover ordering, duplicates, absent scopes, escaped names,
unchanged stored facts and an empty request.

## Install or update

Finish active work and choose **Settings → Updates → App updates → Update & restart**.
For a new installation, download a complete bundle from the
[v1.1.17 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.17).
Preserve your existing data directory.
