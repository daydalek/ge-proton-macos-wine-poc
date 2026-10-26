#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the baseline (upstream Wine 11.0) or media (GE multimedia port) variant.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
variant="${1:?Usage: build-wine.sh baseline|media}"
root="$POC_ROOT"
platform_flags=()
case "$variant" in
  baseline)
    src="$POC_WORK/src/$POC_BASELINE_WINE_DIR"
    if ! test -d "$src"; then src="$POC_SOURCE_ROOT/$POC_BASELINE_WINE_DIR"; fi
    ;;
  media)
    src="$POC_SOURCE_ROOT/$POC_MEDIA_WINE_DIR"
    platform_flags=(--disable-amd_ags_x64 --disable-loader64)
    ;;
  *) echo 'Usage: build-wine.sh baseline|media' >&2; exit 2 ;;
esac
poc_require_path "$src/configure.ac" "run scripts/prepare.py"
poc_setup_wine_build_env
# Wine runs freshly built x86_64 helper tools during the build.
poc_require_rosetta
poc_note "Building $variant from $src (macOS >= $MACOSX_DEPLOYMENT_TARGET, $POC_JOBS jobs)"
mkdir -p "$root/build/$variant" "$root/stage/$variant" "$root/logs/$variant"
if test "$variant" = media; then
  apply_args=()
  for patch_name in macos-platform.patch macos-vmr7-window.patch wow64-demuxer-cleanup.patch quartz-child-window-position.patch quartz-preserve-window-size.patch mpeg-audio-wave-format.patch rosetta-wow64-thunks.patch command-line-append.patch vkd3d-partial-varyings.patch dbghelp-dwarf-divisor.patch sechost-device-notify-handle.patch stale-present-rect.patch opengl-flush-flags.patch macos-fullscreen-surface.patch wow64-present-rect.patch wine-upstream-syscall-wrappers.patch macos-gdi-fullscreen-centering.patch macos-metalfx-spatial.patch macos-gdi-upscalers.patch; do
  patch_file="$POC_PROJECT/patches/wine-ge/$patch_name"
  apply_args+=(--patch "$patch_file")
  done
  "$POC_PYTHON" "$POC_PROJECT/scripts/apply-patch-series.py" --source "$src" "${apply_args[@]}"
  (cd "$src" && "$POC_TOOLS/bin/autoconf" && "$POC_TOOLS/bin/autoheader" && ./tools/make_requests) \
    > "$root/logs/$variant/regenerate.log" 2>&1
  XDG_CACHE_HOME="$root/cache" "$POC_PYTHON" "$src/dlls/winevulkan/make_vulkan" \
    > "$root/logs/$variant/make-vulkan.log" 2>&1
  (cd "$src" && ./tools/make_specfiles) \
    > "$root/logs/$variant/make-specfiles.log" 2>&1
  notice_args=()
  for patch in "$src/../$POC_GE_DIR/patches/ge-video-rework/"*.patch "$POC_PROJECT/patches/wine-ge/"*.patch; do
    notice_args+=(--patch "$patch")
  done
  "$POC_PYTHON" "$POC_PROJECT/scripts/source-notices.py" --source "$src" "${notice_args[@]}"
fi
cd "$root/build/$variant"
"$src/configure" --host=x86_64-apple-darwin \
  --enable-archs=i386,x86_64 --with-mingw=llvm-mingw \
  --with-ffmpeg --with-coreaudio --with-freetype --with-vulkan --with-gnutls \
  --without-x --without-wayland --without-pulse --without-alsa \
  ${platform_flags[@]+"${platform_flags[@]}"} \
  --disable-tests --prefix="$root/stage/$variant" \
  > "$root/logs/$variant/configure.log" 2>&1
make -j"$POC_JOBS" > "$root/logs/$variant/build.log" 2>&1
make install > "$root/logs/$variant/install.log" 2>&1
if test "$variant" = media; then
  "$POC_PYTHON" "$POC_PROJECT/scripts/build-gdi-upscalers.py" --stage "$root/stage/$variant" \
    --work "$root/gdi-upscalers" --jobs "$POC_JOBS" > "$root/logs/$variant/gdi-upscalers.log" 2>&1
fi
echo "Installed: $root/stage/$variant"
