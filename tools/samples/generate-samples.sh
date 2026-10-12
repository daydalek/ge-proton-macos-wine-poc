#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd -P)"
source "$kit/../../scripts/lib/common.sh"
ffmpeg="$POC_DEPS/bin/ffmpeg"
ffprobe="$POC_DEPS/bin/ffprobe"
poc_require_path "$ffmpeg" "run scripts/build-deps.sh"
poc_require_rosetta
/usr/bin/arch -x86_64 "$ffmpeg" -y -v error \
  -f lavfi -i 'testsrc2=size=640x480:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 8 \
  -c:v wmv2 -b:v 1000k -c:a wmav2 -b:a 128k "$kit/test-wmv2.wmv"
/usr/bin/arch -x86_64 "$ffmpeg" -y -v error \
  -f lavfi -i 'testsrc2=size=640x480:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 8 \
  -c:v mpeg1video -b:v 1000k -c:a mp2 -b:a 128k \
  -f mpeg "$kit/test-mpeg1.mpg"
/usr/bin/arch -x86_64 "$ffmpeg" -y -v error \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 8 \
  -c:a pcm_s16le "$kit/test-pcm.wav"
for item in wmv2.wmv mpeg1.mpg pcm.wav; do
  /usr/bin/arch -x86_64 "$ffprobe" -v quiet -show_streams -show_format \
    -of json "$kit/test-$item" > "$kit/test-${item%.*}.json"
done
