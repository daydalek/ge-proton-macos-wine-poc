#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the patched CrossOver Wine core into work/crossover-port/stage.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
mode="${1:-full}"
case "$mode" in full|media) ;; *) echo 'Usage: build.sh [full|media]' >&2; exit 2 ;; esac
port="$POC_CROSSOVER_PORT"
source_dir="$port/sources/wine"
poc_require_path "$source_dir/configure" "run scripts/crossover/prepare-source.sh"
notice_args=(--patch "$POC_PROJECT/patches/crossover/crossover-26.3-media.patch")
for patch_name in quartz-preserve-window-size.patch mpeg-audio-wave-format.patch command-line-append.patch vkd3d-partial-varyings.patch dbghelp-dwarf-divisor.patch sechost-device-notify-handle.patch stale-present-rect.patch opengl-flush-flags.patch macos-fullscreen-surface.patch wow64-present-rect.patch; do
  patch_file="$POC_PROJECT/patches/wine-ge/$patch_name"
  if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_dir" apply "$patch_file"
  else
    git -C "$source_dir" apply --reverse --check "$patch_file"
  fi
  notice_args+=(--patch "$patch_file")
done
python3 "$POC_PROJECT/scripts/source-notices.py" --source "$source_dir" "${notice_args[@]}"

poc_setup_wine_build_env
poc_require_rosetta
poc_note "Building CrossOver core ($mode, macOS >= $MACOSX_DEPLOYMENT_TARGET, $POC_JOBS jobs)"
mkdir -p "$port/build" "$port/stage"
cd "$port/build"
"$source_dir/configure" --host=x86_64-apple-darwin --enable-archs=i386,x86_64 \
  --with-mingw=llvm-mingw --with-ffmpeg --with-coreaudio --with-freetype --with-vulkan \
  --without-x --without-wayland --without-pulse --without-alsa \
  --disable-tests --prefix="$port/stage" > "$port/configure.log" 2>&1
case "$mode" in
  media)
    make -j"$POC_JOBS" dlls/quartz/all dlls/ddraw/all dlls/winedmo/all \
      dlls/qasf/all dlls/wmadmod/all dlls/wmvcore/all dlls/mf/all \
      dlls/mfmediaengine/all dlls/mfplat/all dlls/mfreadwrite/all \
      dlls/mfsrcsnk/all dlls/msauddecmft/all > "$port/build-media.log" 2>&1
    ;;
  full)
    make -j"$POC_JOBS" > "$port/build-full.log" 2>&1
    make install > "$port/install.log" 2>&1
    ;;
esac
