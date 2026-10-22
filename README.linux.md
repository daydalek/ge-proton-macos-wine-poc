# Linux Wine runtime

The Linux target uses the same CrossOver 26.3.0 source archive and GE-Proton11-7
multimedia patch stack as the macOS runtime. It builds an x86_64 Unix core with
i386 and x86_64 Windows modules using new WoW64. The initial distribution target
is Ubuntu 24.04 amd64, with X11, Wayland, ALSA, PulseAudio and Vulkan enabled.

`configs/crossover-patch-series.txt` remains the shared patch authority.
`configs/linux-build.json` records Linux toolchain inputs and two platform
exclusions: macOS Steam command-line defaults and D3DMetal DLL routing.
The generic CommandLineAppend implementation, directory-hook compatibility,
i386 hotpatch rewriter, repeated-seek repair, and all other shared fixes remain
selected. macOS driver patches stay in the prepared source and retain their
platform-specific activation conditions.

## Build

Run these commands inside Ubuntu amd64. On Apple Silicon, an OrbStack machine
can be created with `orb create --arch amd64 ubuntu:24.04 ubuntu-amd64`.
Use the Linux filesystem for the working directory.

```bash
bash scripts/linux/install-deps.sh
export POC_LINUX_WORK_DIR="$HOME/.cache/ge-wine-linux"
export POC_JOBS=4
python3 scripts/linux/build.py all
python3 scripts/linux/build-probes.py --work-dir "$POC_LINUX_WORK_DIR"
```

`build.py prepare`, `deps`, and `wine` expose individual stages. Downloads are
SHA-256 verified. `--archive-cache /path/to/existing/work` can reuse verified
CrossOver and dependency archives from the macOS build. Prepared source inputs
are recorded; select a fresh work directory when changing source patches.
Logs are saved under the work directory's `logs/` folder.

Run the isolated regression suite under a virtual X display:

```bash
xvfb-run -a -s '-screen 0 1280x720x24' python3 scripts/linux/verify.py \
  --work-dir "$POC_LINUX_WORK_DIR"
```

Reports and per-probe logs are kept under `validation/`. The suite uses a
dedicated prefix and a PulseAudio null sink for silent unattended playback.

The Linux PE toolchain is the official LLVM-MinGW 20260616 UCRT release.
FFmpeg is built from the same locked source as macOS with broad built-in
software playback. GnuTLS and desktop/device libraries come from Ubuntu.
The package therefore requires compatible host distro libraries.

## Packaging

```bash
python3 scripts/linux/package.py --work-dir "$POC_LINUX_WORK_DIR" \
  --output "$HOME/wine-linux-release"
```

The fresh output directory receives the runtime, corresponding source archive,
ELF dependency report, patch manifest and checksums. The runtime includes
FFmpeg libraries, licenses, and a `run` launcher with a user-writable prefix.
ELF library search paths use `$ORIGIN` relative paths. The source archive
contains the prepared Wine source, locked input archives and project recipes.
Repeat `verify.py` with `--runtime /path/to/wine-linux-x86_64` after moving the
runtime directory to validate the packaged layout.

## Validation scope

An amd64 OrbStack machine on Apple Silicon uses CPU translation and an ARM64
kernel. It is useful for build checks and software-rendered regression probes.
Native x86_64 Linux desktop validation covers GPU drivers, Wayland/X11 session
behavior, fullscreen/input, real game playback, and performance. Steam Proton
compatibility-tool integration is a separate integration target from this
standalone Wine runtime.
