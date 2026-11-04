# GDI temporal residual implementation

The temporal presenter combines GPU 16x16 change detection, masked residual
composition, independent 256x256 quiet intervals, asynchronous cached Core ML
refinement, and gradual detail reveal.

## Conventional presentation fallback

The Core ML helper uses 18-pixel context and cached overlapping 256x256
windows. The conventional presentation path compares 64x64 patches on the CPU
and presents CGImages. The native NSCursor path is separate from the supplied
GDI surface. Game-rendered cursors and text participate in frame differences.

## Design constraints

- Upload each CPU GDI frame once; detect changes on the GPU in 16x16 groups.
- Keep a GPU reference input and signed linear-light residual atlas.
- Compare current input to its accepted neural reference, including both old
  and new moving content. Dilate masks by context and feather outwards.
- Compose current bilinear baseline plus masked cached residual directly into
  a CAMetalLayer; no full-resolution output readback for presentation.
- Maintain independent 256x256 change timestamps and versions. Refine settled
  tiles after 200 ms while other tiles continue changing.
- Build bounded immutable inference jobs; reuse existing helper tile outputs.
- Validate completion against current input on the GPU before accepting detail.
  Geometry/model generations and source snapshots must match.
- Preserve stable detail when another tile updates. Fade refreshed detail in
  over 100 ms. Keep one active job and bounded presentation resources.
- Full transitions and geometry changes invalidate relevant references. Retain
  a working conventional presentation path if Metal or inference fails.
- Keep window/fullscreen geometry in the existing presentation layer. Region
  selection and manual exclusion remain archived and absent from this path.

## Architecture

A GPU presenter owns source/history textures, reference input, residual,
16x16 difference metadata and the display layer. Only compact change metadata
is read by the scheduling callback. CPU source pixels already originate in GDI
and are retained only for immutable inference snapshots.

Stable scheduling tiles are copied into a hybrid reference input. Other cores
retain the accepted input. Existing halo-aware Core ML windows then infer only
changed inputs. Completion checks the job snapshot against the latest frame;
only matching blocks and their context publish reference/residual updates.
This bounds work without replaying stale text or cursors.

B(X) uses the same bilinear filter and sRGB decode in residual creation and
composition. Residual storage is signed RGBA16Float. Clamping and sRGB encode
occur at final display. Refresh timestamps are per accepted block.

## Block residual library

Accepted (input, residual) state is snapshotted into up to 16 slots after each
successful admission. Every even-offset 16x16 window of a slot input is indexed
by content hash in a per-slot open-addressed table on the GPU. Each presented
frame probes reference-dirty 16x16 blocks against all active slots at the four
parities, so a block can be matched to a source under any pixel translation d.
The first candidate whose 8px context verifies exactly wins; matches found at
parity (0,0) that also verify the full 18px context are *exact* and leave the
dirty set immediately. Other matches are *provisional*: the translated residual
is shown at once but the block stays dirty and is refined by the normal quiet
interval inference, which clears the provisional flag on commit. Matched blocks
publish their current input into the reference and its CPU mirror, and their
verified 8px context ring takes the same residual so stale boundary residual
cannot persist. Slots are replaced LRU-by-last-hit; a new snapshot frees an
older slot only when that slot's differing blocks are still covered by another
active slot. `WINE_GDI_TEMPORAL_LIBRARY_MB` (default 384, 0 disables) bounds
total slot memory. `WINE_GDI_TEMPORAL_TRACE=1` logs per-frame probe counts and
slot store/evict/redundant-free events.

## Integration and validation

Real-CUGAN and adaptive modes dynamically load the optional presenter extension,
submit immutable 2x refinement jobs on the existing serial worker, and show the
native Metal layer. Conventional presentation remains available as a fallback.

Canonical presentation sources live in `native/gdi-upscalers/presentation/`.
`scripts/sync-gdi-temporal-patch.py` synchronizes them into the maintained Wine
patches. Build instructions and dependencies are maintained by the build scripts.

Build success alone does not establish runtime or visual correctness. See
[TEMPORAL-ACCEPTANCE.md](TEMPORAL-ACCEPTANCE.md) for manual regression checks;
game acceptance remains pending.

## WineD3D / OpenGL presentation

The OpenGL swap hook shares the default backbuffer with Metal through a bounded
three-slot IOSurface ring. It preserves framebuffer/texture bindings, default
read buffer, scissor and framebuffer-sRGB state. A vertically flipped GPU blit
normalizes GL coordinates to the existing top-first temporal input. Native
NSCursor rendering stays separate. The transparent hit-test overlay forwards
input to the original Wine content view. Original GL swaps always execute.

Metal copies the surface into private immutable storage before releasing its
producer slot. Difference detection and composition stay on the GPU. Core ML
snapshot readback occurs after quiet-tile selection: the first snapshot seeds
the CPU reference, subsequent snapshots copy selected 256x256 cores. Existing
halo-aware cached inference and GPU stale-result admission remain shared with
GDI. Context/view changes retire overlays; resolution changes invalidate jobs.

This initial inter-API synchronization uses glFinish after the surface blit.
Its frame-time cost requires user measurement. Eligibility follows the existing
Real-CUGAN/adaptive temporal modes and source limit (4096 per edge, 2 Mi pixels).
Vulkan and D3DMetal have separate presentation paths. See
patches/wine-ge/macos-wined3d-temporal.patch and the patch synchronizer.
