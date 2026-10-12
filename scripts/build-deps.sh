#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the x86_64 host tools and libraries Wine links against.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
poc_setup_build_env
test -n "${CMAKE:-}" || poc_die "cmake not found; install it (brew install cmake / port install cmake) or set CMAKE"
root="$POC_ROOT"
tools="$POC_TOOLS"
deps="$POC_DEPS"
mkdir -p "$tools" "$root/src" "$root/build" "$deps" "$root/logs"
poc_note "Deployment target: macOS $MACOSX_DEPLOYMENT_TARGET, jobs: $POC_JOBS"
"$POC_PYTHON" "$POC_PROJECT/scripts/fetch-deps.py"
tar -xJf "$POC_WORK/llvm-mingw.tar.xz" -C "$tools"
tar -xJf "$POC_WORK/m4.tar.xz" -C "$root/src"
tar -xJf "$POC_WORK/bison.tar.xz" -C "$root/src"
tar -xJf "$POC_WORK/autoconf.tar.xz" -C "$root/src"
tar -xzf "$POC_WORK/ffmpeg.tar.gz" -C "$root/src"
tar -xzf "$POC_WORK/freetype.tar.gz" -C "$root/src"
poc_require_path "$POC_LLVM_MINGW/bin" "POC_LLVM_MINGW_DIR in configs/build.env must match the llvm-mingw archive"
# Build tools run on the build machine only; native arch is fine.
export CC=/usr/bin/clang CXX=/usr/bin/clang++
for directory in "$POC_M4_DIR" "$POC_BISON_DIR" "$POC_AUTOCONF_DIR"; do
    name="${directory%%-*}"
    poc_note "Building $directory"
    (cd "$root/src/$directory"
     ./configure --prefix="$tools" > "$root/logs/$name-configure.log" 2>&1
     make -j"$POC_JOBS" > "$root/logs/$name-build.log" 2>&1
     make install > "$root/logs/$name-install.log" 2>&1)
done
poc_note "Building $POC_FREETYPE_DIR"
"$CMAKE" -S "$root/src/$POC_FREETYPE_DIR" -B "$root/build/freetype" \
  -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
  -DFT_DISABLE_BROTLI=ON -DFT_REQUIRE_ZLIB=ON \
  > "$root/logs/freetype-configure.log" 2>&1
"$CMAKE" --build "$root/build/freetype" -j"$POC_JOBS" > "$root/logs/freetype-build.log" 2>&1
"$CMAKE" --install "$root/build/freetype" > "$root/logs/freetype-install.log" 2>&1
SDK_ROOT="$(xcrun --show-sdk-path)" DEPS_ROOT="$deps" "$POC_PYTHON" - <<'PY'
import os, re
from pathlib import Path
sdk = Path(os.environ['SDK_ROOT'])
version = re.search(r'#define ZLIB_VERSION "(.*?)"', (sdk/'usr/include/zlib.h').read_text()).group(1)
Path(os.environ['DEPS_ROOT'], 'lib/pkgconfig/zlib.pc').write_text(
    f'prefix=/usr\nName: zlib\nDescription: macOS SDK/system zlib\nVersion: {version}\nLibs: -lz\nCflags:\n')
PY
poc_note "Building $POC_FFMPEG_DIR"
(cd "$root/src/$POC_FFMPEG_DIR"
 ./configure --prefix="$deps" --cc="$POC_HOST_CC" \
   --arch=x86_64 --target-os=darwin --enable-cross-compile \
   --enable-shared --disable-static --disable-autodetect --disable-x86asm \
   --disable-doc --disable-debug --disable-network --disable-everything \
   --enable-avcodec --enable-avformat --enable-avutil --enable-swscale \
   --enable-swresample --enable-avfilter --enable-indev=lavfi \
   --enable-filter=testsrc2,color,format,aresample,sine,scale \
   --enable-demuxer=asf,mpegps,mpegvideo,avi,mov,wav,mp3 \
   --enable-decoder=wmv1,wmv2,wmv3,vc1,wmav1,wmav2,wmapro,mpeg1video,mpeg2video,mp1,mp2,mp3,pcm_s16le,h264,wrapped_avframe \
   --enable-parser=mpegvideo,mpegaudio,h264,vc1 \
   --enable-encoder=wmv1,wmv2,wmav2,mpeg1video,mp2,pcm_s16le \
   --enable-muxer=asf,mpeg1system,vob,wav,avi --enable-protocol=file \
   --enable-bsf=h264_mp4toannexb,vc1_asftorcv \
   --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wl,-rpath,$deps/lib" \
   > "$root/logs/ffmpeg-configure.log" 2>&1
 make -j"$POC_JOBS" > "$root/logs/ffmpeg-build.log" 2>&1
 make install > "$root/logs/ffmpeg-install.log" 2>&1)
echo "Local dependencies installed: $deps"
