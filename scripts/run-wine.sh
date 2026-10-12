#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Use a separately built Wine under this project's work tree.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
variant="${1:?Usage: run-wine.sh baseline|media /absolute/path/game.exe [args...]}"
shift
case "$variant" in baseline|media) ;; *) echo 'Variant must be baseline or media.' >&2; exit 2;; esac
game="${1:?Provide an absolute EXE path}"
shift
case "$game" in /*) ;; *) echo 'Provide an absolute EXE path.' >&2; exit 2;; esac
test -f "$game" || poc_die "not a file: $game"
stage="$POC_ROOT/stage/$variant"
prefix="$POC_ROOT/prefixes/$variant"
logs="$POC_ROOT/logs/$variant"
poc_require_path "$stage/bin/wine" "run scripts/build-wine.sh $variant"
poc_require_path "$stage/bin/wineserver" "run scripts/build-wine.sh $variant"
poc_require_rosetta
mkdir -p "$prefix" "$logs"
export WINEPREFIX="$prefix"
export WINESERVER="$stage/bin/wineserver"
export WINELOADER="$stage/bin/wine"
export PATH="$stage/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINE_D3D_CONFIG
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH LD_LIBRARY_PATH
export WINEDEBUG="${POC_WINEDEBUG:-+timestamp,+pid,+tid,+loaddll,+quartz,+dmo,+wmvcore}"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
log="$logs/$stamp.log"
echo "Log: $log"
cd "$(dirname "$game")"
{
  echo "Wine: $stage/bin/wine"
  echo "Prefix: $prefix"
  /usr/bin/file "$stage/bin/wine" "$game"
  /usr/bin/arch -x86_64 "$stage/bin/wine" --version
  /usr/bin/arch -x86_64 "$stage/bin/wine" wineboot -u
  /usr/bin/arch -x86_64 "$stage/bin/wine" "$game" "$@"
} > "$log" 2>&1
