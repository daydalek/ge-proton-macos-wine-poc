# Working notes

## Core ML helper and content cache

`native/gdi-upscalers/src/coreml-helper.mm` is built standalone for arm64, not
through CMake:

```sh
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc \
    -Wall -Wextra -Werror -I native/gdi-upscalers/include \
    native/gdi-upscalers/src/coreml-helper.mm \
    -framework Foundation -framework CoreML -framework Accelerate -o winegdi-coreml-helper
codesign --force --sign - winegdi-coreml-helper
```

Tests that exercise it need a resources directory containing
`coreml/<family>-WxH.mlmodelc` bundles; prepared trees live under
`work/esrgan/stage/lib/wine/x86_64-unix/gdi-upscalers` (realcugan +
animevideov3 tiles) and `work/coreml/prepared` (realcugan only, includes the
odd-sized `realcugan-65x49` that selects the exact-frame path). Models do not
need rebuilding for helper changes.

```sh
python3 native/gdi-upscalers/tests/coreml-cache-test.py \
    /path/to/winegdi-coreml-helper /path/to/gdi-upscalers
```

The cross-scene content store (`src/content-cache.h`) is header-only C++17 and
has a synthetic test independent of Core ML:

```sh
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
    native/gdi-upscalers/tests/content-cache-test.cpp \
    -I native/gdi-upscalers/src -o /tmp/wgdi-cache-test && /tmp/wgdi-cache-test
```

The temporal block residual library (multi-slot translated residual reuse) has
a Metal test driving the real presenter through `presentImage` + synthetic jobs:

```sh
xcrun clang++ -std=c++17 -O2 -fno-objc-arc -Wall -Wextra \
    -I native/gdi-upscalers/include \
    native/gdi-upscalers/tests/temporal-library-test.mm \
    -framework Foundation -framework AppKit -framework Metal \
    -framework QuartzCore -framework IOSurface -framework CoreGraphics \
    -o /tmp/wgdi-temporal-library-test
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 /tmp/wgdi-temporal-library-test \
    /path/to/build-dir/gdi-upscalers   # dir containing temporal.metallib
```

Runtime knobs: `WINE_GDI_TEMPORAL_LIBRARY_MB` (default 384; 0 disables the
block residual library), `WINE_GDI_TEMPORAL_TRACE=1` (probe/admission/slot
logging), `WINE_GDI_CACHE_MODE=off|memory|persistent` (default memory),
`WINE_GDI_CACHE_MEMORY_MB`, `WINE_GDI_CACHE_DISK_MB`,
`WINE_GDI_CACHE_DIRECTORY` (absolute override, otherwise
`~/Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler/<namespace>` where the
namespace hashes `WINEPREFIX` + `WINE_GDI_CACHE_GAME`),
`WINE_GDI_COREML_DISABLE_TILE_CACHE` disables both tile cache tiers for the
uncached reference, `WINE_GDI_COREML_TRACE` prints per-frame
inferred/reused/stored counts. The ncnn CPU fallback path is uncached.

## Regional Core ML API and protocol v2

`wgdi_upscaler_process_regions` is an optional ABI-1-compatible export: drivers
resolve it with dlsym and fall back to `process` when absent. The temporal
presenter's optional `selectedTilesForToken:` supplies the per-tile mask. The
helper protocol v2 extends the mmap by 32 bytes (256-bit tile selection
bitset); old helpers reject the extended mapping and the client retries once
with the legacy mapping. Old clients/helpers keep v1 full-frame behavior.

Regional inference is covered by:

```sh
python3 native/gdi-upscalers/tests/coreml-regions-test.py \
    /path/to/winegdi-coreml-helper /path/to/gdi-upscalers
```

which needs the helper plus `coreml/<family>-WxH.mlmodelc` bundles like the
cache test, and validates selected bytes against v1 output, unselected
sentinels, same-socket bad-mask recovery, and legacy v1 mapping.

Exact-translation capability is declared per model in
`resources/coreml/manifest.json` under `temporal_models.<model>` with integer
`input_halo` 19..64, integer `dependency_halo` exactly 19, and
`integer_translation` a real JSON boolean true. Models built before the
halo-19 contract must be re-converted (input `[1,3,W+38,H+38]`) before
`animevideov3` exact translation engages; missing or malformed manifests fail
closed to provisional-only reuse.

The isolated-resources path in `gdi-upscalers-test` accepts a second argument:
`./gdi-upscalers-test <ncnn-model-dir> <isolated-resources>` where the second
directory holds only the helper plus compiled `.mlmodelc` bundles (no ncnn CPU
models), exercising the real CoreMLBackend regions/full paths without CPU
fallback.

## CI source tests and dependency-free native tests

`scripts/ci/run-source-tests.py` runs `tools/tests` through unittest
discovery, writes a JSON report (default `outputs/checks/source-tests.json`),
and fails on failures, errors, unexpected successes, skips whose reason is
not listed via `--allow-skip REASON` (exact match, repeatable), an empty
suite, or a suite where every discovered test was skipped:

```sh
python3 scripts/ci/run-source-tests.py --output outputs/checks/source-tests.json \
    --allow-skip 'Linux audio tools are required' \
    --allow-skip 'Build native library and set WGDI_TEST_NATIVE_LIBRARY' \
    --allow-skip 'Optional window-free GPU/reference comparison' \
    --allow-skip 'i686-w64-mingw32-clang not found' \
    --allow-skip 'x86_64-w64-mingw32-clang not found'
```

The allowed-skip set above is the macOS CI leg; the Linux leg's exact
reasons live beside it in `.github/workflows/build-release.yml`. Those sets
are the intentional skip scope per platform: every other test must execute,
so a missing host compiler, patch, or audio tool fails instead of silently
greening. On Linux the `i686/x86_64-w64-mingw32` ABI checks resolve
`<triple>-clang` on PATH, then `<triple>-gcc` (gcc-mingw-w64 packages), then
the pinned local llvm-mingw toolchain.

Two neural-free native tests (frame-diff, exclusion compare) build on any
host without models, ncnn, xcrun, or Objective-C; the CommonCrypto
content-cache and coreml-client tests are Apple-only:

```sh
cmake -S native/gdi-upscalers -B outputs/checks/native-build \
    -DWGDI_TESTS_ONLY=ON -DWGDI_TEST_SANITIZERS=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build outputs/checks/native-build --parallel 2
ctest --test-dir outputs/checks/native-build --output-on-failure --no-tests=error
```

`WGDI_TESTS_ONLY=ON` requires `BUILD_TESTING=ON` and returns before the
Apple/ncnn/model/Python checks; the normal build stays macOS-only and keeps
`gdi-upscalers-test` in the full configure. Test executables always build
with `-UNDEBUG`, so Release keeps assertions live; `WGDI_TEST_SANITIZERS=ON`
adds target-scoped `-fsanitize=address,undefined -fno-sanitize-recover=all`
(Clang/GNU compilers only). Run the suite as a non-root user: the exclusions
test relies on `chmod 000` denying reads, which root bypasses.

## DirectDraw windowed/exclusive probes and single-module rebuilds

`tools/probes/ddraw-windowed-restore-probe.c` covers the black window after
leaving a smaller exclusive mode (exit 0 pass, 1 fail, 2 mode unavailable).
It needs a prefix where 800x600 can be set, so on Retina hosts set
`HKCU\Software\Wine\X11 Driver\EmulateModeset=Y` in a scratch prefix first;
the window readback assertion only engages with `WINE_D3D_CONFIG=renderer=gdi`
(other renderers still assert the blit result):

```sh
work/poc/tools/llvm-mingw-*/bin/i686-w64-mingw32-clang -Wall -Wextra -Werror -O2 \
    tools/probes/ddraw-windowed-restore-probe.c -o /tmp/ddraw-windowed-restore-probe-x86.exe \
    -lddraw -ldxguid -luser32 -lgdi32
WINE_D3D_CONFIG=renderer=gdi wine /tmp/ddraw-windowed-restore-probe-x86.exe
```

A single PE module can be rebuilt without the full build from a configured
out-of-tree build directory of the prepared CrossOver source:

```sh
source scripts/lib/common.sh && poc_setup_wine_build_env
make -C work/crossover-port/region-deploy-1793638787/build dlls/ddraw/all
```

The prepared tree is owned by `scripts/apply-patch-series.py`; when its
`.ge-patch-series.json` stamp predates the current series, re-prepare it
instead of editing files in place.
