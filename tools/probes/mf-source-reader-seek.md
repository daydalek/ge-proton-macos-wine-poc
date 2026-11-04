# Source Reader seek timestamp probe

The probe checks that decoded sample timestamps and `ReadSample` response timestamps
agree after forward and backward absolute seeks, including a seek back to zero.
It expects an H.264 MP4 with a keyframe on every 30 fps frame and at least two
seconds of video. It does not play sound or open a game window.

On macOS, generate a fresh fixture and build both probe architectures:

```sh
swift tools/probes/mf-source-reader-make-fixture.swift /tmp/mf-seek-fixture.mp4
bash tools/probes/build-probes.sh
```

Run `mf-source-reader-seek-probe-x64.exe` and `mf-source-reader-seek-probe-x86.exe`
with the Wine runtime under test, passing the Windows path of the generated MP4.
Both should print `failures=0` and exit successfully. The unfixed reader resets
its response timestamps after a nonzero seek and reports nonzero failures.
