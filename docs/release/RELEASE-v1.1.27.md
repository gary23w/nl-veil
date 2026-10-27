# the veil v1.1.27

The stable fix for v1.1.26, which on many machines would not open. A veil started while another one is already running gets a working server again, and a veil that cannot start now says why instead of disappearing.

## What changed

- **A second veil opens onto a working server.** When another veil was already running on the same machine, for example an earlier one still in the tray (closing the window hides the veil there rather than quitting it), a newly started veil moved to the next free port, as it has since v1.1.21. It then started its built-in model endpoint, which looks for a free port from 8788 upward and took the very port the app had just chosen, because the app's server binds it only a moment later. The app's own server then failed to start, and its window opened with nothing behind it, behind a "could not start on port" message. The endpoint now leaves the app's port alone. Started beside a running veil, the fixed build served on 8789 with its built-in endpoint on 8790, and the desktop connected to it.
- **A veil that cannot start says why.** A veil launched by double-click runs without a console, so when startup failed before the window opened it ended with nothing on screen at all. v1.1.26 made one more startup step fatal: it refuses to run on an account store it cannot read completely. Any such failure now shows a message with the reason and saves it as `startup-error.txt` in the data folder. When the reason is `NeuronCommandFailed`, the memory engine beside the veil did not run or could not read the account store; on Windows that engine needs the Microsoft Visual C++ runtime (`VCRUNTIME140.dll`), and the message says so.

## Verification

`scripts/check.ps1 -Full` passed all nine gates on the release tree: model-catalog sync, web assets, the Taters runtime suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the merged desktop build. The server test suite ran 1,120 tests with one platform skip, and the desktop suite 337.

The fixed build was started three ways on Windows: beside a running veil (it served on 8789, its built-in endpoint on 8790, and the desktop connected), from a clean folder by double-click with the default all-interfaces bind (window and server up), and on an unreadable account store (the message box appeared and `startup-error.txt` named `NeuronCommandFailed`). The v1.1.26 bundle itself opened normally on this machine from a clean folder, by double-click, from folders with spaces and non-ASCII characters in their names, and over a used v1.1.25 install. It failed only beside a running veil, so whatever other machines hit beyond that is what the new message is for.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory. A veil still running in the tray from an earlier install keeps its own port and data; quit it there if you only want the new one.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.27-windows-x86_64.zip` |
| Linux x86-64 | `veil-v1.1.27-linux-x86_64.zip` |
| macOS Apple Silicon | `veil-v1.1.27-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.27-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately. Everything in [v1.1.26](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.26.md) is included.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.26...v1.1.27) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.27/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
