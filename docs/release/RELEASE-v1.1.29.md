# the veil v1.1.29

Less memory held for nothing. On Windows, every thread the veil started charged its whole 16 MiB stack to the computer's commit limit the moment it started, and the server set aside one 16 MiB request buffer for each of its 128 request threads before the first request arrived. An idle veil therefore held gigabytes of commit while its working set stayed small. This release commits what the veil uses. Mac apps also stop asking for the build machine's macOS.

## What changed

- **Threads commit what they use.** On Windows a thread now commits 256 KiB of stack when it starts instead of 16 MiB. The rest of its 16 MiB stack is committed only when the thread grows into it, so it can still go exactly as deep as before. This covers every thread the veil's own code starts in the server, the desk and the built-in model engine, the web server's request threads, and the runtime pools the server and the desk use for background I/O. On Linux and macOS a thread's stack already took memory only as it was used, and nothing changes there.
- **A small pool of request buffers.** The server keeps 16 pooled request-body buffers of 256 KiB instead of 128 of 16 MiB. A larger request body, up to the same 16 MiB limit, gets a buffer of its own for that request.
- **Named threads.** On Windows each thread now carries a name, `veil:<role>` (the request threads are `veil:http`), which a debugger or Process Explorer shows.
- **Mac apps ask for macOS 13.0.** The v1.1.28 Mac apps recorded the build machine's macOS as the oldest macOS they run on: 15.8.2 on Apple silicon and 15.7.9 on Intel. Mac builds now record macOS 13.0, and the release workflow fails a Mac bundle or Mac server that asks for more before attaching it.

## Verification

Measured on Windows with server builds started on their own port and data folder, idle for a minute, 133 threads each: the code before this change committed 4,174 MiB, 260 blocks of about 16 MiB among it; this release's code committed 51 MiB, none of them. The default build, with the built-in model engine compiled in, idled at 183 MiB when run as a server. The desktop app with its window open was not measured. Request bodies from 2 KB to 12 MiB, and 24 one-megabyte bodies sent at once, were answered the same before and after the change; a 17 MiB body is over the limit in both.

`scripts/check.ps1` passed on Windows (the server build, the server and desk test suites, and the Linux compile of the tests), the default Windows build compiled, and `scripts/check.sh --full` passed in CI on Linux. Every bundle on this page passed the release workflow's processor check, the macOS minimum check where it applies, and the packaged-app smoke test on its build machine before it was attached. A test build of the Apple silicon bundle with the macOS 13.0 minimum started on macOS 14.8.9 and passed the packaged-app smoke test; it has not been started on macOS 13, or on an Intel Mac older than macOS 15.

Not changed here: when the built-in model engine is compiled in, its own request server still sets aside 8 request buffers of 16 MiB (128 MiB) at start.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.29-windows-x86_64.zip` |
| Windows x86-64 with AVX2 | `veil-v1.1.29-windows-x86_64-avx2.zip` |
| Linux x86-64 | `veil-v1.1.29-linux-x86_64.zip` |
| Linux x86-64 with AVX2 | `veil-v1.1.29-linux-x86_64-avx2.zip` |
| macOS Apple Silicon | `veil-v1.1.29-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.29-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately. Everything in [v1.1.28](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.28.md) is included.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.28...v1.1.29) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.29/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
