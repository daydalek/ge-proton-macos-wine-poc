#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Install locked Vulkan headers and the official MoltenVK x86_64 runtime.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
poc_setup_build_env
"$POC_PYTHON" - "$POC_PROJECT" "$POC_WORK" <<'PY'
import json, sys
from pathlib import Path
project, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(project / 'scripts/lib'))
from poc_common import download_verified
for item in json.loads((project / 'configs/dependency-lock.json').read_text()):
    if item['archive'] in ('MoltenVK-macos.tar', 'vulkan-headers.tar.gz'):
        download_verified(item['url'], work / item['archive'], item['sha256'])
PY
mkdir -p "$POC_ROOT/src" "$POC_DEPS/include" "$POC_DEPS/lib/pkgconfig"
tar -xf "$POC_WORK/MoltenVK-macos.tar" -C "$POC_ROOT/src"
tar -xzf "$POC_WORK/vulkan-headers.tar.gz" -C "$POC_ROOT/src"
cp -R "$POC_ROOT/src/$POC_VULKAN_HEADERS_DIR/include/vulkan" "$POC_DEPS/include/"
cp -R "$POC_ROOT/src/$POC_VULKAN_HEADERS_DIR/include/vk_video" "$POC_DEPS/include/"
moltenvk="$POC_ROOT/src/$POC_MOLTENVK_DIR/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
poc_require_path "$moltenvk" "official MoltenVK macOS archive layout changed"
arches="$(/usr/bin/lipo -archs "$moltenvk")"
case " $arches " in *' x86_64 '*) ;; *) poc_die "MoltenVK archive lacks x86_64 support" ;; esac
if test "$arches" = x86_64; then
  cp "$moltenvk" "$POC_DEPS/lib/libMoltenVK.dylib"
else
  /usr/bin/lipo "$moltenvk" -thin x86_64 -output "$POC_DEPS/lib/libMoltenVK.dylib"
fi
/usr/bin/install_name_tool -id '@rpath/libMoltenVK.dylib' "$POC_DEPS/lib/libMoltenVK.dylib"
/usr/bin/codesign --force --sign - "$POC_DEPS/lib/libMoltenVK.dylib"
"$POC_PYTHON" - "$POC_DEPS" "$POC_VULKAN_HEADERS_DIR" <<'PY'
import sys
from pathlib import Path
prefix = Path(sys.argv[1])
version = sys.argv[2].split('Vulkan-Headers-', 1)[1]
(prefix / 'lib/pkgconfig/vulkan.pc').write_text(
    f'prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n'
    f'Name: Vulkan\nDescription: Vulkan headers and MoltenVK macOS runtime\nVersion: {version}\n'
    'Libs: -L${libdir} -lMoltenVK\nCflags: -I${includedir}\n')
PY
poc_note "Installed Vulkan headers and x86_64 MoltenVK: $POC_DEPS"
