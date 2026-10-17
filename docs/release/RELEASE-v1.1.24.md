# the veil v1.1.24

Portable application downloads built from the current cleaned source.

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

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** once the release is published. Platform checksum files and standalone server builds are provided separately.

## Verification

The release workflow runs the full acceptance gates and native bundle/version, installation, updater and Cloudflare transport checks. Every platform must pass before publication. Manual release builds remain drafts for final artifact-content verification.

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.24/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
