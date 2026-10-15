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
poc_load_crossover_patches
# The base media port is part of the prepared import and later patches overlap
# it, so only the remaining series entries are applied or verified here.
notice_args=(--patch "$POC_PROJECT/${POC_CROSSOVER_PATCHES[0]}")
for patch_name in "${POC_CROSSOVER_PATCHES[@]:1}"; do
  patch_file="$POC_PROJECT/$patch_name"
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
    # Record successful compilation inputs beside the installed core.
    python3 - "$POC_PROJECT" "$source_dir" "$port/stage" "${POC_CROSSOVER_PATCHES[@]}" <<'PY_BUILD'
import hashlib, json, pathlib, subprocess, sys
project, source, stage = map(pathlib.Path, sys.argv[1:4])
lock = json.loads((project / 'configs/crossover-source-lock.json').read_text())
patches = sys.argv[4:]
modules = ['bin/wine', 'bin/wineserver', 'lib/wine/x86_64-unix/win32u.so',
           'lib/wine/x86_64-unix/winemac.so', 'lib/wine/x86_64-windows/wow64win.dll']
record = {'core': 'crossover-ge-media', 'baseline': 'CrossOver ' + lock['cross_over_version'],
          'source_archive_sha256': lock['source_sha256'],
          'source_commit': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
          'source_dirty': bool(subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip()),
          'patches': {name: hashlib.sha256((project / name).read_bytes()).hexdigest() for name in patches},
          'compiled_modules': {name: hashlib.sha256((stage / name).read_bytes()).hexdigest() for name in modules}}
(stage / '.wine-build-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
PY_BUILD
    ;;
esac
