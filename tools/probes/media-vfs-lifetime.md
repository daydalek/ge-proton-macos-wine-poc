# Quartz media probe lifetime

`patches/crossover/quartz-vfs-probe-lifetime.patch` keeps a media stream alive
between type detection and source-filter loading. It is applied after
`quartz-filesource-vfs-fallback.patch` by the shared patch series.

## Failure mechanism

An archive-backed Win32 file hook may free its decoded stream cache when its
last virtual handle closes. Quartz's preliminary media-type probe opens and
closes a handle before the source filter opens the same path. With affected
hooks, reopening produces empty reads and `RenderFile` returns `0x80040218`.

The probe may return `FALSE` after successfully opening a file, so ownership
of the optional returned handle is independent of the media-type match result.
The caller initializes/receives `INVALID_HANDLE_VALUE` when no file was opened.
`RenderFile` retains a valid handle across source selection and ASF fallback;
`AddSourceFilter` retains it until source loading completes. Both close it on
all terminal paths. The source filter keeps its own handle after success.
The nested probe in `FileSource_Load` keeps the original close behavior because
the filter already owns an open stream handle.

The fix uses application-independent handle ownership. Its code contains no
game names, paths, virtual-handle magic values, or translation-DLL assumptions.
It complements the earlier legacy-size/synchronous-I/O compatibility patch.

## Probe

`tools/probes/build-probes.sh` builds `media-vfs-lifetime-probe-x86.exe` and
`media-vfs-lifetime-probe-x64.exe` with the project's LLVM-MinGW toolchain.
The probe creates and releases a graph without starting playback:

```text
media-vfs-lifetime-probe-x86.exe render Z:\fixtures\video.mpg
media-vfs-lifetime-probe-x86.exe source Z:\fixtures\video.mpg
media-vfs-lifetime-probe-x86.exe missing Z:\fixtures\absent.mpg
media-vfs-lifetime-probe-x86.exe render Z:\fixtures\virtual.mpg Z:\fixtures\hook.dll
```

`render` requires `S_OK`. `source` uses `AddSourceFilter` and verifies that
`IAsyncReader::SyncRead` returns a full MPEG program-stream header. `missing`
requires the render operation to fail after graph creation succeeds.

For a hook gated on executable name, copy the probe under that expected name
in an isolated fixture directory. Supply the user's own hook and read-only
archive there. Keep the absolute path spelling consistent with the executable
path: aliases such as `/tmp` and `/private/tmp` can affect hook prefix matching.
The hook DLL and game resources are external fixtures, excluded from the repo.

## Validation (2026-10-26)

- i386 and x86_64 Quartz builds completed; the i386 runtime was deployed.
- The original virtual-file reproduction changed from `0x80040218` to `S_OK`.
- Six i386 cases passed: virtual rendering, virtual source/full-header read,
  an exported translation video, ordinary MPEG, ASF, and missing-file failure.
- The user confirmed the original in-game OP playback was repaired.

This confirms the installed macOS/Wine/game combination. Other VFS hooks,
native Windows behavior, and upstream Wine integration need their own evidence.
The patch is based on this repository's prepared CrossOver source and existing
ASF source-selection changes. A clean upstream submission requires rebasing
and a separately distributable synthetic VFS fixture.

## Repeat-load coverage

`repeat-render` and `repeat-source` run three complete create/use/release rounds
in one process, loading the optional hook once. They cover resources released
between independent graphs. A successful first graph alone does not establish
repeat-load compatibility.

Follow-up investigation found that the specific translation DLL also omits a
reference-count increment when reusing an unloaded cache descriptor. With the
Wine probe-lifetime patch, round one passes and later source reads return
`S_FALSE`. A checksum-scoped local correction to that DLL passed three source
and three render rounds. This application-specific defect is separate from
the generic probe-handle ownership patch; the proprietary DLL is an external
fixture. The user confirmed repeated in-game playback after skipping and reloading on 2026-10-26.

### Reproducing the version-specific DLL correction

The local repair is reproducible with `scripts/patch-eustia-vfs.py`:

```sh
python3 scripts/patch-eustia-vfs.py /path/to/original/Game.dll /path/to/Game.dll.repaired
```

The tool requires original SHA-256
`699e1c51f74b46a8f34397203a4da0318808fcd7393815abda7f570ffc046648`
and verifies output SHA-256
`5b5677650f304c49338b2b54afe6af5a4f050959bf81b14a67d43d70f614fcab`.
It creates a new output exclusively; preserve the original and exit the game
before installing the output as `Game.dll`. Restore the original for rollback.
The generated binary is locally modified, including any signature validity;
its output hash identifies the verified repair. The repository contains the
repair recipe and regression tools; users supply their own licensed DLL.

At RVA `0x5e2d`, a trampoline preserves the new-descriptor allocation branch
and adds the missing reference for an existing unloaded descriptor through
the original helper at RVA `0x33f0`. It uses verified padding at RVA `0x25f00`
and extends the `.text` virtual size to cover that code. All branches are
relative. This correction applies exclusively to the hash above.

Automated same-process comparisons: the original DLL fails later rounds of
both repeat modes; the corrected DLL passes all three rounds of each mode.
The user additionally confirmed the in-game skip/read-save/replay sequence.
