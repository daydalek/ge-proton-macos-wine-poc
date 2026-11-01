# Real-CUGAN Core ML tiling

The game runtime uses `native/gdi-upscalers/src/coreml-helper.mm`. Whisky's
Swift image helper processes library covers separately.

The helper selects a fixed-size tile model for each frame geometry. Models
up to 384x384 are preferred for sparse updates; the default bundle includes a
256x256 model. Candidates are ranked by total inferred pixels. Larger models
remain usable when a small model is absent. Exact odd-size models provide a
fallback when no even tile model is available.
Each window samples the original frame with an 18-pixel reflect-101 halo.
Window origins align to the network's stride-2 pooling phase. Outputs overlap
by at least 32 source pixels and blend with normalized weights; reflected
padding outside the frame is cropped. Input/output tensors and feature
providers are reused between frames. A per-window autorelease pool bounds
prediction object lifetimes. Output dimensions, strides and finite values are
validated before stitching.

Core ML uses CPU_AND_NE; Core ML decides individual operation placement.
Hardware failures retain the client's existing CPU fallback. Arbitrary input
sizes use tiled Core ML when a compatible compiled model is available. The
public GDI API's frame limits still apply.

Build the helper with the flags in `scripts/build-realcugan-coreml.py`, then run:

```sh
python3 native/gdi-upscalers/tests/coreml-tiling-test.py HELPER RESOURCES
python3 native/gdi-upscalers/tests/coreml-tiling-test.py HELPER RESOURCES 800x600 801x601 1280x720
```

For the default small-image regression use a bundle containing only the
64x48 test model. This exercises multiple tiles, odd dimensions, single-pixel
reflection, full output coverage, constant-frame seams and repeated frames.
The second command exercises the production model bundle. Run outside an
execution sandbox that restricts Core ML model/device access.

A local production-bundle probe on 2026-11-01 measured warmed helper time of
116 ms at 800x600, 201 ms at 801x601 and 259 ms at 1280x720. These measurements
include conversion/stitching and exclude Wine presentation. They demonstrate
resolution coverage; game frame-rate acceptance requires a separate game test.
Real-CUGAN's global statistics can vary between windows, so detailed game
screenshots also need visual inspection for texture changes across seams.

## Incremental cache

Each grid position retains its reflected BGRA input window and quantized RGB
output. Exact comparison covers the complete 18-pixel halo, so changes also
invalidate neighbouring windows whose context changed. Unchanged windows reuse
their cached output; the full frame is blended again in deterministic order.
Geometry changes reset the cache. Entries are published after successful output
validation. The cache holds one frame geometry per helper; memory scales with
frame area and overlap. Full transitions still infer every tile.

Set `WINE_GDI_COREML_TRACE=1` to report inferred/reused tile counts per frame.
Set `WINE_GDI_COREML_DISABLE_TILE_CACHE=1` for full tiled reference inference.
The cache regression compares textured frames, sparse changes, halo changes,
image edges, repeated frames and geometry changes byte for byte:

```sh
python3 native/gdi-upscalers/tests/coreml-cache-test.py HELPER RESOURCES 801 601
```

With a 256x256 model at 801x601, a local probe measured 218 ms for all 12 tiles,
43 ms for a small change (2 inferred, 10 reused), and 7 ms for a repeated frame.
These are helper times on synthetic input; game-level transitions and visual
quality still require observation in the game.

## Persistent presentation

The Wine display adapter retains the last neural image during local updates.
It partitions presentation into 64x64 source patches and compares each patch
plus an 18-pixel context against the completed job's immutable input. Matching
patches draw from the neural result; changed patches draw the current surface
(MetalFX in adaptive mode, low-cost interpolation in Real-CUGAN mode).
Output geometry changes use the normal initial presentation path. Clips use
integer destination boundaries and account for CoreGraphics row orientation.

In adaptive mode, sparse changes (at most one quarter of the image estimated
in 64-pixel row spans) schedule refinement immediately. Broad changes retain
the quiet-interval policy. One active job and the latest snapshot bound the
queue. Display composition checks the current snapshot, so a stale completed
job contributes only matching patches. The first neural result still requires
initial inference; scene-wide changes refresh the full image.

`tools/tests/test_gdi_upscalers.py` exercises this through the actual patched
Objective-C adapter, including synthetic neural pixels, a changed corner,
fractional scaling, active jobs, and adaptive scheduling.
