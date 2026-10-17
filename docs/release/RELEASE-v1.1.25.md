# the veil v1.1.25

What a swarm lineage proposes for its memory is now reviewed under that lineage, in the desktop's **Swarm → Lineages** view, with each proposal's whole text on screen. The chat's Memory tab goes back to holding only what the chat keeps for you.

## What changed

- **Lineage proposals moved to Swarm → Lineages.** When a cast runs under a lineage id, its end-of-run judge and habit miner propose lessons, skills, habits and facts for that lineage's memory and hold them for review. The desktop drew every pending proposal, up to 16, in the chat's Memory tab, above your saved memories, although a kept proposal only ever reaches a later cast of that lineage and never a chat. Each lineage's card in Swarm → Lineages now lists its own pending proposals below its cast history, one card each with **keep** and **drop**. Keeping and dropping work as before.
- **A proposal's whole text is readable.** The old cards wrapped text at a fixed character count, splitting words, and showed at most six lines, so a long lesson was cut off before its end. The new cards wrap at word boundaries to the card's width and show every line.
- The lineage card's counts line adds how many proposals await review. The "review N proposal(s)" button, which jumped to the chat's Memory tab, is gone.

## Release tooling

- Each platform's checksum file lists the files attached to the release under the names they download as. The standalone server builds lose their `server-only/` folder prefix, and the bundle manifest, which is not attached, is no longer listed.
- `scripts/bump-version.ps1` stamps the direct download links the README's install table and the site's Download buttons have used since v1.1.24. Before this it refused to bump at all, because the site no longer has the release-page link it used to stamp.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release tree: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build. The server test suite ran 1,025 tests with one platform skip, and the desktop suite 309.

The desktop change passed the desktop test suite and the merged desktop build on its own commit. The new Lineages layout has not yet been looked at in a running desktop: no lineage with pending proposals existed when it was built.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.25-windows-x86_64.zip` |
| Linux x86-64 | `veil-v1.1.25-linux-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.25-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.25-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.24...v1.1.25) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.25/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
