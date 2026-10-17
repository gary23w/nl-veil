# the veil v1.1.24

Portable application downloads built from cleaned main commit [7b54f295](https://github.com/gary23w/nl-veil/commit/7b54f2950a8957cbcdf82f312a44407db1a832c0).

## Changes

- The retired bundled security runtime and its deployment sources are excluded from the application and release bundles. Optional security tools connect to the managed service using an API key.
- Source examples and documentation use sanitized data.
- Official portable bundles contain only the application, memory engine, launchers, installation marker, license and readme. Packaging checks reject unexpected files, source archives, runtime data and symbolic links.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.24-windows-x86_64.zip` |
| Linux x86-64 | `veil-v1.1.24-linux-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.24-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.24-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. Platform checksum files and standalone server builds are provided separately.

## Verification

The full acceptance gates and native installation, version, updater and Cloudflare transport checks passed on Windows, Linux, Apple Silicon macOS and Intel macOS. All 21 assets passed GitHub SHA-256 and published-checksum verification. Each portable bundle contains exactly seven approved files. Targeted private-data and retired-runtime fingerprint checks passed before publication.

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.24/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
