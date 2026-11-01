# GDI temporal residual implementation

Goal: GPU 16x16 change detection, masked temporal residual composition,
independent 256x256 quiet intervals, asynchronous cached Core ML refinement,
and gradual detail reveal. Game/UI acceptance is performed by the user.
Computer Use remains disabled. Commit each coherent implementation stage.

## Existing baseline

The Core ML helper uses 18-pixel context and cached overlapping 256x256
windows. Wine currently compares 64x64 patches on the CPU and presents CGImages.
The native NSCursor path is separate from the supplied GDI surface.
Game-rendered cursors and text participate in frame differences.

## Required end state

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
- Compile shader, Objective-C glue, x86_64 native library and arm64 helper;
  commit changes and deploy with --manual-verification. User checks games.

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

## Evidence and handoff

Record compilation and commit IDs per stage. Authoritative implementation lives
in native/gdi-upscalers and the maintained Wine patch. Keep generated build
sources synchronized. Existing functional probes can be extended as artifacts;
run game, inference and UI checks only at the user's explicit request.
Completion requires the full implemented path and documented user acceptance;
unverified game behavior remains pending.
