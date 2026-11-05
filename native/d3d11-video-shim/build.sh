#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the d3d11 video-device shim for both Windows architectures.
# Usage: build.sh [output-dir]   (default: work/d3d11-video-shim)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
source "$here/../../scripts/lib/common.sh"
toolchain="$POC_LLVM_MINGW/bin"
out="${1:-$here/../../work/d3d11-video-shim}"
poc_require_path "$toolchain/i686-w64-mingw32-clang" "run scripts/build-deps.sh"
for target in i686:x32 x86_64:x64; do
    triple="${target%%:*}"
    arch="${target##*:}"
    mkdir -p "$out/$arch"
    "$toolchain/$triple-w64-mingw32-clang" -shared -static -Wall -Wextra -Werror -O2 \
        "$here/d3d11-video-shim.c" "$here/d3d11.def" -o "$out/$arch/d3d11.dll" \
        -Wl,--kill-at -ldxguid -luuid
    echo "built $out/$arch/d3d11.dll"
done
