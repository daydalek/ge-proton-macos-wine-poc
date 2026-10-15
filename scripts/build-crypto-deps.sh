#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Private x86_64 GnuTLS dependency chain for Wine bcrypt and Schannel.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
poc_setup_build_env
poc_require_rosetta
mkdir -p "$POC_ROOT/src" "$POC_ROOT/build" "$POC_DEPS" "$POC_ROOT/logs"
"$POC_PYTHON" - "$POC_PROJECT" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/lib'))
from poc_common import CONFIGS, POC_ROOT, WORK, download_verified, extract_tar
names = {'gmp.tar.xz', 'nettle.tar.gz', 'libtasn1.tar.gz', 'libunistring.tar.xz', 'gnutls.tar.xz'}
for item in json.loads((CONFIGS / 'dependency-lock.json').read_text()):
    if item['archive'] in names:
        archive = download_verified(item['url'], WORK / item['archive'], item['sha256'])
        extract_tar(archive, POC_ROOT / 'src')
PY
export CC="$POC_HOST_CC" CXX="$POC_HOST_CXX" CC_FOR_BUILD=/usr/bin/clang
export CPPFLAGS="-I$POC_DEPS/include"
export LDFLAGS="-L$POC_DEPS/lib -Wl,-rpath,$POC_DEPS/lib"
export PKG_CONFIG_LIBDIR="$POC_DEPS/lib/pkgconfig:$POC_DEPS/share/pkgconfig"
export PKG_CONFIG_PATH=''
export ABI=64
build_library() {
  local directory="$1" name="$2"
  shift 2
  poc_note "Building x86_64 $directory"
  mkdir -p "$POC_ROOT/build/$name"
  (cd "$POC_ROOT/build/$name"
   "$POC_ROOT/src/$directory/configure" --host=x86_64-apple-darwin \
     --prefix="$POC_DEPS" --enable-shared --disable-static "$@" \
     > "$POC_ROOT/logs/$name-configure.log" 2>&1
   make -j"$POC_JOBS" > "$POC_ROOT/logs/$name-build.log" 2>&1
   make install > "$POC_ROOT/logs/$name-install.log" 2>&1)
}
build_library "$POC_GMP_DIR" gmp --disable-assembly --disable-cxx
build_library "$POC_NETTLE_DIR" nettle --disable-assembler --disable-documentation
build_library "$POC_LIBTASN1_DIR" libtasn1 --disable-doc
build_library "$POC_LIBUNISTRING_DIR" libunistring
build_library "$POC_GNUTLS_DIR" gnutls --disable-doc --disable-tools \
  --disable-tests --disable-cxx --disable-nls \
  --without-p11-kit --without-idn --without-tpm --without-tpm2 \
  --without-zlib --without-brotli --without-zstd
poc_note "GnuTLS installed: $POC_DEPS/lib/libgnutls.dylib"
