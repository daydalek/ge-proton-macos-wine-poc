#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the tested opt-in host-memory workaround from pinned upstream sources.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
poc_setup_build_env
root="$POC_WORK/moltenvk-shadow"
test ! -e "$root" || poc_die "shadow build already exists: $root; use a fresh POC_WORK_DIR"
mkdir -p "$root"
git clone --depth 1 --branch v1.4.2 https://github.com/KhronosGroup/MoltenVK.git "$root/src"
test "$(git -C "$root/src" rev-parse HEAD)" = db66022459ffb663aa2b50f6b018bc2e124f5edf || poc_die 'unexpected MoltenVK source revision'
curl -fL https://github.com/gauthierpiarrette/MoltenVK/commit/f1d0c316be9a062e2f4fe8ce020db7c5687d2fc6.patch -o "$root/shadow-import.patch"
echo "399f3cce04e8a65dc87901ed434380b91a3c7737e5ea53db332237fbbbaf938d  $root/shadow-import.patch" | shasum -a 256 -c -
# The code applies to 1.4.2; only the newer release-notes context differs.
git -C "$root/src" apply --check --exclude=Docs/Whats_New.md "$root/shadow-import.patch"
git -C "$root/src" apply --exclude=Docs/Whats_New.md "$root/shadow-import.patch"
cd "$root/src"
env -u CC -u CXX ./fetchDependencies --macos
env -u CC -u CXX xcodebuild build -project MoltenVKPackaging.xcodeproj \
  -scheme 'MoltenVK Package (macOS only)' -destination 'generic/platform=macOS' \
  -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -quiet
lib="$root/src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
test -f "$lib" || poc_die 'shadow MoltenVK build missing'
strings "$lib" > "$root/strings.txt"
grep -Fq MVK_CONFIG_SHADOW_IMPORTED_HOST_MEMORY "$root/strings.txt" || poc_die 'shadow configuration marker missing'
mkdir -p "$POC_DEPS/lib"
cp "$lib" "$POC_DEPS/lib/libMoltenVK.dylib"
poc_note 'Built opt-in MoltenVK shadow-import workaround (off by default)'
