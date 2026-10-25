# GE-Proton macOS Wine PoC

For the shared-patch Linux x86_64 build, isolated regression suite and packaging,
see the [Linux build guide](README.linux.md). Validation scope is recorded in each build report.

English | [简体中文](README.md)

An experimental proof-of-concept (PoC) and patch suite that ports **GE-Proton's multimedia decoding and playback rework** to **Apple Silicon (macOS / Rosetta 2)**.

This project builds on the open-source Wine, Valve Wine, and CrossOver Wine cores and ports the 64 multimedia rework patches from [GE-Proton11-7](https://github.com/GloriousEggroll/proton-ge-custom/tree/GE-Proton11-7). The core multimedia rework comes from GloriousEggroll and other upstream contributors.

This project's additions focus on Apple Silicon/macOS build adaptations, video window presentation, coordinate and size fixes, and WoW64 compatibility adaptations. See [UPSTREAMS.md](UPSTREAMS.md) for sources, authors, and licenses.

The project addresses common audio and video issues in Wine on macOS:

- Video decoding failures caused by the absence of the GStreamer multimedia pipeline
- Quartz playback crashes and misplaced 32-bit DirectShow child windows
- Black or transparent VMR7 video windows
- WoW64 thunk exceptions under Rosetta 2 and demuxer destruction crashes

Two source bases are supported: **Valve Wine (GE-Proton 11-7)** and **CrossOver Wine 26.3**.

---

## Repository layout

```text
ge-proton-macos-wine-poc/
├── patches/                            # Core porting patches
│   ├── wine-ge/                       # Wine / GE-Proton adaptations (platform, VMR7, Quartz, WoW64, etc.)
│   └── crossover/                     # CrossOver Wine 26.3 multimedia port
├── scripts/                            # Automated build and test scripts
│   ├── build-deps.sh                  # Build x86_64 dependencies (FFmpeg, FreeType, autoconf, etc.)
│   ├── prepare.py                     # Fetch and prepare sources, then apply patches
│   ├── build-wine.sh                  # Build GE-Proton Wine (baseline / media variants)
│   ├── run-wine.sh / run-packaged.sh  # Run Wine environments and games
│   ├── package.py                     # Create a standalone distribution package
│   ├── static-check.py                # Check dependencies and minimum macOS versions
│   └── crossover/                     # CrossOver Wine build scripts (prepare-source.sh, build.sh)
├── tools/
│   ├── probes/                        # Windows test probes (DirectShow, child windows, SEH exceptions)
│   └── samples/                       # Audio and video test samples (WMV2, MPEG-1, PCM)
├── configs/                            # Build settings and source/dependency version locks
└── outputs/                            # Build and package output
```

---

## Getting started

### Requirements

- An Apple Silicon Mac with Rosetta 2 (`softwareupdate --install-rosetta`)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.9+, CMake, pkg-config, and Git

### Option A: Build Wine with the GE-Proton patches

```bash
# 1. Download and build the x86_64 toolchain and dependencies (including FFmpeg)
bash scripts/build-deps.sh

# 2. Prepare sources and apply patches
python3 scripts/prepare.py

# 3. Build Wine with the multimedia patches (media variant)
bash scripts/build-wine.sh media
```

> For an upstream reference build, run `bash scripts/build-wine.sh baseline`.

#### FFmpeg format coverage

`scripts/build-deps.sh` enables all dependency-satisfied built-in decoders, demuxers,
parsers and bitstream filters in the locked FFmpeg source, rather than a playback
allowlist. This includes WMA Lossless, AAC, Vorbis, Opus, FLAC, MPEG-4, HEVC and
VP8/VP9. Encoders, muxers and filters remain limited to synthetic sample generation.

External-library autodetection, networking, hardware acceleration and
GPL/nonfree/version3 components are disabled, retaining an LGPL-2.1-or-later
FFmpeg build. Optional third-party codecs are not bundled. Actual coverage depends
on the locked source and dependencies; FFmpeg support does not guarantee Wine
integration or game playback.

#### Wine cryptography and TLS

Dependency builds also compile private x86_64 GnuTLS, GMP, Nettle/Hogweed,
libtasn1 and libunistring. Existing builds can run `bash scripts/build-crypto-deps.sh`
before reconfiguring and rebuilding Wine. Wine explicitly requires GnuTLS, so a
missing backend fails configuration instead of silently disabling cryptography.
Whisky packages bundle these libraries and use `@rpath` loading, without Homebrew
paths or disabling certificate verification. Full CI checks the bundled libraries
and relocatable crypto backend names. These dependencies have their own licenses,
independent of FFmpeg; see [UPSTREAMS.md](UPSTREAMS.md).

#### Run a game and test playback

```bash
# Compile the Windows test probes (.exe), including DirectShow probes
bash tools/probes/build-probes.sh

# Run your game or application
bash scripts/run-wine.sh media /path/to/game.exe
```

---

### Option B: Build from the CrossOver Wine 26.3 sources

To build using the official CrossOver Wine 26.3 source base:

```bash
# 1. Complete scripts/build-deps.sh first
# 2. Download and extract the CrossOver Wine sources, then apply the GE media port
bash scripts/crossover/prepare-source.sh

# 3. Build the CrossOver Wine core
bash scripts/crossover/build.sh full

# Optional: rebuild only the 12 multimedia modules
bash scripts/crossover/build.sh media
```

The patch order is recorded in `configs/crossover-patch-series.txt`. The build ports upstream wine's syscall parameter-normalization wrappers (commit `f43402c`): the Unix side is built with clang, which assumes callers have zero/sign-extended small integer arguments (`BOOLEAN`, `UCHAR`, …), whereas the Win64 ABI leaves their upper bits undefined. Without the wrappers, garbage upper bits from Windows callers keep Steam's connection coroutine (`YieldingConnect`) from starting. `wine.inf` also seeds default `HKCU\Software\Wine\AppDefaults\<exe>\CommandLineAppend` values for `steam.exe` and `steamwebhelper.exe` without overwriting existing values; set an empty string to disable one.

The standalone runtime is installed to `work/crossover-port/stage`. Your existing CrossOver application and bottles remain unchanged.

#### Whisky graphics backend selection

The CrossOver loader supports Whisky's `WINED3DMETAL=0` by loading Wine's original
`dxgi`, `d3d10`, `d3d10core`, `d3d11`, and `d3d12` builtins from
`Wine/lib/wine/wined3d/{x86_64,i386}-windows/`, without attaching Apple's Unix
bridges. Full builds and Whisky packaging preserve these same-build DLLs as
runtime components, independent of GPTK rollback backups. Selection is per
process and does not mutate shared DLLs or bottles. Missing originals fail
explicitly rather than silently loading D3DMetal. Other variable values leave
normal loading unchanged; native DXVK/DXMT selection is unaffected, and build-tree
execution continues to use the original build outputs.

WineD3D's `WINE_D3D_CONFIG=renderer=gl` or `renderer=gdi` still requires selecting
WineD3D. GDI disables 3D, so D3D11 device creation should fail in that mode. This
patch changes DLL routing, not WineD3D's or D3D12's graphics capabilities.

#### i386 legacy Windows hotpatch prologue compatibility

Under `-fms-hotpatch`, `llvm-mingw` (Clang + LLD) emits a two-byte `66 90` NOP at
32-bit PE function entries and fills inter-section padding with `0xcc`.
`patches/crossover/i386-hotpatch-prologue.patch` maps `DECLSPEC_HOTPATCH` on Clang
i386 to `__patchable_function_entry__(8, 6)` and `__noinline__`, rewrites `66 90`
entries preceded by five `0x90` bytes to `8b ff` (`mov edi, edi`) during
`winebuild --builtin`, and annotates `CreateFontIndirectA`, `GetGlyphOutlineA`,
`EnumFontFamiliesExA`, and `AppendMenuA` alongside the existing `CreateWindowExA`
and `SetWindowTextA` hotpatch markers.

#### WMP ActiveX embedded playback

`patches/crossover/wmp-activex-player2-embedding.patch` adds an IDL-generated
`IWMPPlayer2` interface, player properties and state, pause/close handling, and
preserves the activated window when a host sets the same site again. The
DirectShow video window follows the control's parent and size. Embedded playback
on macOS prefers a VMR9 child surface; other drivers retain normal DirectShow
renderer selection. Behavior is selected by hosting mode and driver.

Both `full` and `media` builds include `wmp.dll`. The probe checks interfaces,
ATL embedding and silent playback. Supply a video longer than five seconds:

```sh
bash tools/probes/build-probes.sh
wine tools/probes/wmp-probe-x86.exe
wine tools/probes/wmp-probe-x86.exe --embed
wine tools/probes/wmp-probe-x86.exe --embed 'Z:\path\to\video.wmv'
```

Use `wmp-probe-x64.exe` for x64 coverage. Exit code 0 indicates probe success.
Visual presentation, synchronization and frame pacing require host-application
validation. The implementation covers windowed video playback; full WMP skins,
fullscreen and true windowless video remain separate implementation work.

---

## Packaging and release checks

Create a portable package from the build output and inspect its minimum system requirements:

```bash
# 1. Compile the probes
bash tools/probes/build-probes.sh

# 2. Create the portable package (default: outputs/wine-poc/)
python3 scripts/package.py

# 3. Check Mach-O dependencies and minimum macOS versions
python3 scripts/static-check.py
```

Runtime data generated by the portable package (prefixes, caches, and logs) is stored by default in:

```text
~/Library/Application Support/GE-Proton macOS Wine PoC
```

Set `WINE_POC_DATA=/path/to/data` to choose a different location.

---

## Build settings and environment variables

Edit [configs/build.env](configs/build.env) or override its settings through environment variables:

```bash
# Requested minimum macOS deployment target (default: 11.0)
export POC_MACOSX_DEPLOYMENT_TARGET=11.0

# Parallel build jobs
export POC_JOBS=8

# Custom work directory (use a clean directory when changing deployment targets)
export POC_WORK_DIR="$PWD/work"
```

---

## License

- Project-authored scripts, probe code, and documentation use **LGPL-2.1-or-later**. See [COPYING.LIB](COPYING.LIB).
- Third-party sources and patches (Wine, GE-Proton, FFmpeg, FreeType, etc.) retain their original licenses. See [UPSTREAMS.md](UPSTREAMS.md) for versions and attribution; license texts are provided in `licenses/`.

## CI builds and releases

GitHub Actions uses the hosted `xcode-27` preview runner by default to build the x86_64 Wine core for macOS 27+ Apple Silicon with Rosetta 2. Branch pushes and pull requests run source and syntax checks. Manual runs build the complete package and upload artifacts. Pushing a `v*` tag creates a GitHub prerelease after a successful build.

Each release provides a runtime package, corresponding sources, licenses, build provenance, and SHA256 checksums. Wine and build dependencies are built from locked archives in an isolated work directory; MoltenVK uses a verified official macOS binary archive. Both Wine cores enable Vulkan, and the runtime includes x86_64 MoltenVK. Full remote build and target-device playback acceptance depend on the actual results.

Run the workflow manually from Actions and inspect the artifacts before creating a version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The repository variable `MACOS_BUILD_RUNNER_JSON` can override the runner selection, for example `["self-hosted", "macOS", "ARM64", "macos-27"]`. The workflow checks the actual macOS version, arm64 host architecture, and Rosetta environment.

Full CI builds inspect the final Libraries FFmpeg dylibs for common game formats
and LGPL licensing. `Libraries-ffmpeg-capabilities.json` lists the actual registered
formats and is included in the release assets, `release-manifest.json` and
`SHA256SUMS`. Missing required codecs such as WMA Lossless or AAC fail the build.
This check launches neither Wine nor games and is not playback acceptance.
The `libraries_only` job only repackages and smoke-tests the pinned older released
core; it does not rebuild FFmpeg or validate current codec coverage. Use the default
full build to release the updated decoding libraries.
