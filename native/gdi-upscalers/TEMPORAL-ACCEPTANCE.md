# User acceptance for GPU temporal GDI upscaling

Functional and visual acceptance is performed by the user. Computer Use and
automated game interaction are disabled for this workflow. Compilation alone
establishes buildability; the observations below establish runtime acceptance.

## Installed path

Use the GPUI Whisky application and a GDI game with Real-CUGAN or adaptive
upscaling selected. Restart the game after runtime deployment. Region selection
remains archived. Existing native system cursors continue through NSCursor.

The startup log should include `Wine temporal: GPU presentation active`.
`WINE_GDI_TEMPORAL_TRACE=1` adds selected tile counts, accepted block counts and
periodic GPU command timing. `WINE_GDI_COREML_TRACE=1` shows inferred/reused
model windows. `WINE_GDI_TEMPORAL=0` selects the conventional presentation path
for a user-controlled comparison after restarting the game.

## Required observations

1. Windowed orientation, colours and text positions match conventional display.
   Static background details remain steady during typing and cursor motion.
2. New text and a game-drawn cursor appear promptly; old positions clear without
   a shadow. Mask boundaries blend smoothly at 16x16 and 256x256 boundaries.
3. A settled area refines after its own 200 ms quiet interval plus inference
   time. Another area continuing to animate does not postpone that refinement.
   Refreshed detail fades in over 100 ms.
4. A full scene transition replaces old content immediately through the current
   baseline. Completing an older job preserves the newer content.
5. Resize, enter/leave fullscreen and change game resolution during inference.
   Composition follows the existing Wine frame geometry. Older geometry and
   job tokens contribute no detail to the new geometry. No selector opens.
6. After initial refinement and fade, an idle game stops generating refinement
   jobs and presentation timers. Closing/minimizing a window remains responsive.
7. Both upscaling modes use the temporal path when available. The conventional
   path remains usable with WINE_GDI_TEMPORAL=0 or a missing temporal shader.

Record game name, source resolution, mode, scene and relevant log lines with
any visible defect. Frame rate, GPU time and inference counts are measurements
for the actual hardware/game, with no guaranteed performance claim from build
results alone.

## Current evidence

- Metal 2.3 kernels compiled and linked for the macOS 11 deployment target.
- x86_64 native library compiled with the temporal factory exported.
- Wine integration compiled against the optional extension and retained the
  original ABI and presentation fallback.
- User game acceptance: pending.
