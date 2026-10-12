#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd -P)"
source "$kit/../../scripts/lib/common.sh"
toolchain="$POC_LLVM_MINGW/bin"
poc_require_path "$toolchain/i686-w64-mingw32-clang" "run scripts/build-deps.sh"
for target in i686 x86_64; do
    case "$target" in i686) bits=x86;; x86_64) bits=x64;; esac
    "$toolchain/$target-w64-mingw32-clang" -Wall -O2 -municode \
      "$kit/media-probe.c" -o "$kit/media-probe-$bits.exe" \
      -lole32 -loleaut32 -lstrmiids -luuid
    "$toolchain/$target-w64-mingw32-clang" -Wall -O2 -municode \
      "$kit/child-window-probe.c" -o "$kit/child-window-probe-$bits.exe" \
      -lole32 -loleaut32 -lstrmiids -luuid
    "$toolchain/$target-w64-mingw32-clang" -Wall -Wextra -O2 \
      "$kit/exception-probe.c" -o "$kit/exception-probe-$bits.exe"
    "$toolchain/$target-w64-mingw32-clang" -Wall -O2 -municode \
      "$kit/reconnect-probe.c" -o "$kit/reconnect-probe-$bits.exe" \
      -lole32 -loleaut32 -lstrmiids -luuid
    "$toolchain/$target-w64-mingw32-clang" -Wall -O2 -municode \
      "$kit/mpeg-audio-format-probe.c" -o "$kit/mpeg-audio-format-probe-$bits.exe" \
      -lole32 -loleaut32 -lstrmiids -luuid
done
