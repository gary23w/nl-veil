# the veil v1.1.28

The release for every processor. v1.1.26 and v1.1.27 would not open on most computers: the Windows app was compiled for the processor of the machine that built it, which had AVX-512, and it stopped before showing a window on any processor without AVX-512. This release is built to run on any 64-bit processor of its platform, and adds separate AVX2 downloads for newer processors.

## What changed

- **Built for every processor.** The build never named a target processor, so each release was compiled for whatever processor the build machine had. The Windows app in v1.1.26 and v1.1.27 used AVX-512 instructions from its first moments, and the v1.1.25 Windows app depended on AVX and BMI instructions the same way. Every build now targets its platform's baseline processor unless told otherwise: any 64-bit x86 processor on Windows and Linux, a Core 2 or later on Intel Macs, and M1 or later on Apple silicon. The built-in model engine now compiles its AVX2 kernels only into AVX2 builds; elsewhere it uses the engine's plain C kernels. The Microsoft Store package is built the same way.
- **AVX2 downloads for newer processors.** Windows and Linux also get an AVX2 bundle (x86-64-v3: AVX2, FMA and BMI2), in which the built-in model's CPU kernels use AVX2. It needs a processor with AVX2; the regular bundle is built for every 64-bit processor of its platform. An AVX2 install updates from the AVX2 downloads, and every other install updates from the regular ones. The GPU (Vulkan) backend is the same in both.
- **Checked before release.** The release workflow now disassembles every bundled app before attaching it and fails the release when it finds an instruction beyond the bundle's level: any AVX, AVX-512, BMI or MOVBE instruction in a regular bundle, or any AVX-512 instruction in an AVX2 bundle. The default build is checked the same way on every change to main, and the Store package before it is submitted.
- **Apple silicon bundle built on macOS 15.** GitHub retires its macOS 14 build machines on 2 November 2026, so the Apple silicon bundle is now built on macOS 15.

## Verification

`scripts/check.sh --full` passed in CI on Linux, followed by the new processor check on the default build it produced. Each x86-64 bundle on this page passed the processor check for its level, and every bundle passed the packaged-app smoke test on its build machine, before it was attached. The check itself was run against the published v1.1.25, v1.1.26 and v1.1.27 Windows apps: it rejects v1.1.26 and v1.1.27 at both levels for their AVX-512 instructions, and v1.1.25 at the regular level for its AVX and BMI instructions. This release has not been started on a processor without AVX; the evidence for older processors is that disassembly.

## Install or update

Download the full bundle for your platform from this release, extract it, and run `veil.exe` on Windows or `./start` on macOS/Linux. Finish active work before updating and preserve your existing data directory. If v1.1.26 or v1.1.27 never opened on your computer, its in-app updater cannot run either: download the regular bundle below.

| Platform | Full application bundle |
|---|---|
| Windows x86-64 | `veil-v1.1.28-windows-x86_64.zip` |
| Windows x86-64 with AVX2 | `veil-v1.1.28-windows-x86_64-avx2.zip` |
| Linux x86-64 | `veil-v1.1.28-linux-x86_64.zip` |
| Linux x86-64 with AVX2 | `veil-v1.1.28-linux-x86_64-avx2.zip` |
| macOS Apple Silicon | `veil-v1.1.28-macos-arm64.zip` |
| macOS Intel | `veil-v1.1.28-macos-x86_64.zip` |

Existing portable installations from v1.1.3 onward that open can use **Settings → Updates → App updates → Update & restart** with this release. On Windows you can also install from the [Microsoft Store](https://apps.microsoft.com/detail/9MVQ78SK0CW6). Platform checksum files and standalone server builds are provided separately. Everything in [v1.1.27](https://github.com/gary23w/nl-veil/blob/main/docs/release/RELEASE-v1.1.27.md) is included.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.27...v1.1.28) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## License

NL-Veil app code uses the [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.28/LICENSE). Dependencies retain their own licenses. The external security service implementation is not bundled.
