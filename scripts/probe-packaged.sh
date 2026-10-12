#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
variant="${1:-media}"
bits="${2:-x86}"
mode="${3:-play}"
sample="${4:-wmv2}"
renderer="${5:-default}"
skip_ms="${6:-0}"
case "$bits" in x86|x64) ;; *) exit 2;; esac
case "$mode" in play|reader) ;; *) exit 2;; esac
case "$renderer" in default|gdi|vmr7|vmr9) ;; *) exit 2;; esac
case "$sample" in
  wmv2) file="$root/samples/test-wmv2.wmv" ;;
  mpeg1) file="$root/samples/test-mpeg1.mpg" ;;
  pcm) file="$root/samples/test-pcm.wav" ;;
  /*) file="$sample" ;;
  *) echo 'Sample must be wmv2, mpeg1, pcm, or an absolute media path.' >&2; exit 2;;
esac
windows_file="Z:${file//\//\\}"
exec "$root/run.sh" "$variant" "$root/media-probe-$bits.exe" \
  "$mode" "$windows_file" "$renderer" "$skip_ms"
