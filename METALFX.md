# GDI upscaling for Galgame

These opt-in Wine macOS driver patches scale opaque GDI window images to the
display's backing pixel resolution. On a 2× Retina display, an 800×600 GDI image
is presented at 1600×1200. Game coordinates, input,
window geometry, and fullscreen letterboxing retain their existing behavior.

## Enable

In the Whisky source, the Bottle's **GDI 超分算法** graphics picker offers:

| Value | Option | Execution |
| --- | --- | --- |
| `off` | 关闭 | Standard Wine presentation; default |
| `metalfx` | MetalFX Spatial | MetalFX GPU scaling with an identical-frame cache |
| `anime4k` | Anime4K (CNN x2 S) | Official v4.0.1 four-convolution x2 S network ported to Metal; background execution |
| `realcugan` | Real-CUGAN (models-se x2) | Official 20220728 model; optional arm64 Core ML FP16 CPU/ANE helper, with ncnn FP32 CPU fallback |
| `adaptive` | 动态 MetalFX／静态 Real-CUGAN | MetalFX during image changes; Real-CUGAN after a 250 ms quiet interval |

Restart the game after changing the choice. The original `metalFXSpatial`
boolean migrates to `metalfx`; an explicit new choice takes precedence. Whisky
saves this independently from the existing D3DMetal DLSS/MetalFX option. Both
GPUI and SwiftUI expose the picker. The shared configuration schema filters it
to macOS.

Direct Wine launch:

```sh
WINE_GDI_UPSCALER=anime4k /path/to/wine /path/to/game.exe
WINE_GDI_UPSCALER=realcugan /path/to/wine /path/to/game.exe
WINE_GDI_UPSCALER=adaptive /path/to/wine /path/to/game.exe
WINE_GDI_UPSCALER=off /path/to/wine /path/to/game.exe
```

The environment is read once per process. `WINE_GDI_UPSCALER` takes precedence
over the original `WINE_METALFX=spatial` alias. The driver logs `Wine MetalFX: GDI
Spatial <input> -> <output> on <GPU>` when it creates a scaler. A log entry
identifies activation; screenshots and gameplay establish visual suitability.

## Coverage and implementation

- Opaque GDI window surfaces, including software-rendered legacy games, use the
  hook in `WineContentView.updateLayer`. The existing fullscreen crop removes
  allocation padding before scaling. A presentation sublayer preserves the
  original surface and physical input geometry.
- MetalFX requires macOS 13+ and a GPU accepted by `supportsDevice:`. The framework
  loads dynamically, preserving the macOS 11 Wine driver deployment target.
  Earlier OS versions, unavailable GPUs, allocation failures, GPU errors, shaped
  windows, and per-pixel alpha windows use standard presentation.
- OpenGL contexts and their descendants, Vulkan/DXVK, and D3DMetal surfaces use
  their respective existing presentation paths. DirectDraw coverage depends on
  whether the selected renderer ultimately submits a GDI window surface.
- Output targets the native backing resolution. 1× displays and surfaces already
  rendered at backing resolution retain standard presentation. Fullscreen
  letterboxing and game resolution remain controlled by Wine and the game.

Input uses sRGB-encoded BGRA8Unorm and MetalFX's Perceptual mode. Input and output
texture usage comes from the scaler; output storage is private. A shared upload
buffer and a shared readback buffer bridge Core Graphics and Metal. The scaler,
textures, bitmap context, and staging buffers are reused until dimensions change.
Command completion precedes reuse; each returned CGImage owns immutable bytes.

The MetalFX path performs synchronous GPU work and CPU readback on the
presentation thread. The identical-frame cache suppresses repeated GPU work.
Text, line art, and detailed CGs need per-game visual comparison.

## Frame differences and adaptive scheduling

All algorithms share an exact active-pixel comparison. The capture bitmap and
its context are reused; immutable input snapshots are created when pixels
change. Identical input pixels and output geometry reuse the previous image.
Every active byte participates, so isolated text/cursor changes invalidate the
cache. Padding bytes are excluded. Input geometry and output size form part of
frame identity.

Anime4K and Real-CUGAN run through a versioned C ABI in
`libwinegdiupscalers.dylib`, next to `winemac.so`. One serial utility worker per Wine process
bounds concurrent inference; a view retains one active job and its latest
snapshot. Completion requests a redraw on the main queue. A result is presented
when its source pixels and geometry match the current frame. This makes static
CG and dialogue scenes suitable for the asynchronous modes. Changing scenes use
Wine's standard presentation while their neural result is pending.

Adaptive mode retains a separate MetalFX cache. Any image or size change starts
a new 250 ms quiet interval and immediately uses MetalFX. A main-queue timer
requests a redraw at the quiet deadline, including when the game has stopped
painting. Stable frames submit one Real-CUGAN job, retain MetalFX while it runs,
and adopt its result after exact source verification. Further changes return to
MetalFX immediately. Failed neural initialization/inference leaves adaptive mode
on MetalFX; an unavailable MetalFX device leaves Wine's standard presentation.

The two CNN backends process a genuine 2× image and resample to the backing
target when required. Their input limit is 2,097,152 pixels with each dimension
at most 4096; their output axes are within `(input, 2×input]`. Adaptive mode
retains its fast path outside these neural limits. Real-CUGAN uses one full
frame for its SE global pooling, with reflect101 padding of 18, even dimension
padding, and two CPU fallback inference threads. Full-frame inference preserves that
model's global context. Standard presentation covers unsupported sizes and
missing resources.

## Core ML / Apple Neural Engine backend

The Real-CUGAN backend automatically selects a bundled fixed-resolution Core ML
model when its exact source size is present. Both `realcugan` and `adaptive`
use this backend through the existing ABI. The Wine driver and Whisky setting
retain their existing values. `WINE_GDI_REALCUGAN_BACKEND=cpu` selects the ncnn
reference path for diagnostics. Restart the game after changing environment.

The x86_64 library launches `gdi-upscalers/winegdi-coreml-helper`, an arm64
executable. An anonymous, immediately unlinked file provides at most 40 MiB of
shared pixel storage; a private socket publishes one request/reply at a time.
No listening network socket, shell command, persistent image file or global
service is used. The helper exits with its owning context. A 45-second request
deadline bounds model load/prediction stalls; disconnects and spawn failures
disable that context's helper and select the ready CPU fallback. Model/inference
errors disable the affected shape. Unsupported dimensions select CPU directly.
The Wine worker owns all helper I/O, while adaptive mode keeps its fast image.

The helper loads an FP16 `mlprogram` with `CPU_AND_NE`. Core ML selects actual
operation placement. `MLComputePlan` reports anticipated placement and cost;
the probe records these separately from observed latency. The helper requires
macOS 13+. The source graph and FP16-stored weights are read directly from the
same SHA256-locked ncnn model, with explicit convolution/deconvolution layouts,
SE reduction, activation, crop and skip operations. The original preprocessing,
full-frame SE context, odd-dimension crop and BGRA output conversion are retained.

Build tools run only on the developer/CI machine:

```sh
python3 -m venv work/coreml-venv
work/coreml-venv/bin/python -m pip install -r scripts/requirements-coreml.txt
python3 scripts/build-gdi-upscalers.py --work work/gdi-upscalers \
  --stage work/gdi-upscalers-stage --test \
  --coreml-python work/coreml-venv/bin/python
```

The default Core ML source sizes are 640×480, 800×600, 1024×768, 1280×720 and
1920×1080. Repeat `--coreml-size WxH` to build an explicit set instead.
`WGDI_COREML_PYTHON` also enables this option in the existing Wine build scripts.
The builder stages the signed helper, compiled `.mlmodelc` directories, portable
`.mlpackage` inputs and a source/tool/file-hash manifest. Existing Libraries
packaging includes these sidecars and MIT licenses. End users download them with
the runtime and select the existing Real-CUGAN/adaptive option.

Window-free validation uses `tools/probes/coreml-realcugan-probe.py` with an
independent x86_64 ncnn reference library. It compares gradients, random noise and
flat black frames, verifies odd sizes and invalid-header handling, and records
cold total time, warm total time, prediction time, pixel errors, PSNR and the
compute plan. FP16 comparison gates are max error ≤16/255 and PSNR ≥40 dB on
these synthetic fixtures. Target-game visual acceptance remains a separate step.

## Source builds

`scripts/crossover/build.sh full` and the media variant of `scripts/build-wine.sh`
build the native library, shader, and model sidecars into their isolated Wine
stage. Source builds require CMake, Python 3.9+, and Xcode's Metal toolchain
(`xcrun --sdk macosx --find metal`). Fixed dependency archives, model weights, and the vendored Anime4K shader
are SHA256 locked in `native/gdi-upscalers/dependencies.json`. Release source
archives include ncnn and the converted Real-CUGAN source/model archive. Runtime
model loading uses local sidecars. The original MIT and BSD license texts ship
beside them.
Ordered source preparation verifies overlapping patches in a temporary tree,
preserves generated modification notices, and retains local changes outside the
patched hunks. A conflicting source edit leaves the original source in place.

```sh
python3 scripts/build-gdi-upscalers.py --work work/gdi-upscalers \
  --stage work/gdi-upscalers-stage --test
WGDI_TEST_NATIVE_LIBRARY="$PWD/work/gdi-upscalers-stage/lib/wine/x86_64-unix/libwinegdiupscalers.dylib" \
  python3 -m unittest tools.tests.test_gdi_upscalers -v
```

The build stage is an output directory. Updating the installed Whisky app/Wine
and game visual acceptance are separate steps. This extension was verified with
compilation and window-free automated checks: real Real-CUGAN model inference,
frame-difference/stability sanitizers, cache hit counts, stale result rejection,
timer-driven adaptation, failure fallback, settings migration and environment
mapping. A small-gradient GPU test also compared the actual Anime4K Metal output
against a CPU evaluation of the original GLSL weights within two 8-bit levels.

## Earlier standalone MetalFX probe

`tools/probes/metalfx-spatial-probe.m` uses the actual helper from the patch,
runs silently, and opens zero windows. Build against a prepared patched source:

```sh
driver=/path/to/patched-wine/dlls/winemac.drv
clang -arch x86_64 -mmacosx-version-min=11.0 -fblocks -Wall -Wextra -Werror \
  -I"$driver" tools/probes/metalfx-spatial-probe.m "$driver/cocoa_spatial.m" \
  -framework AppKit -framework Metal -o /tmp/metalfx-spatial-probe
WINE_METALFX=off /tmp/metalfx-spatial-probe disabled
WINE_METALFX=spatial /tmp/metalfx-spatial-probe
```

Exit 77 reports an unavailable framework or GPU. Tests cover colors and
orientation, retained frames across later submissions, size changes, odd row
pitches, and invalid/downscale sizes. On Apple M2, both arm64 and Rosetta x86_64
executed MetalFX successfully. The six-frame 800×600 → 1600×1200 probe measured
approximately 3.01 ms/frame on arm64 and 4.80 ms/frame on x86_64, including setup,
readback, and verification overhead. These values describe the synthetic probe.

## Research sources

[Apple's spatial scaler documentation](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor)
defines the single-frame input/output contract and GPU capability query.
[Apple's Metal feature tables](https://developer.apple.com/metal/capabilities/)
list spatial scaling support by GPU family. The installed Xcode SDK
`MTLFXSpatialScaler.h` supplies the texture usage, private output storage, color
processing, and deployment availability requirements used by this implementation.
The Anime4K shader and network originate in [Anime4K v4.0.1](https://github.com/bloc97/Anime4K/tree/v4.0.1).
Real-CUGAN model and preprocessing details come from
[nihui's 20220728 conversion](https://github.com/nihui/realcugan-ncnn-vulkan/tree/20220728),
with the model developed by [bilibili](https://github.com/bilibili/ailab/tree/main/Real-CUGAN).
