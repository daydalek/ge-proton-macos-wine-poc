#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
variant="${1:?Usage: run.sh baseline|media /absolute/path/game.exe [args...]}"
shift
case "$variant" in baseline|media) ;; *) exit 2;; esac
game="${1:?Provide an absolute EXE path}"
shift
case "$game" in /*) ;; *) echo 'Provide an absolute EXE path.' >&2; exit 2;; esac
test -f "$game"
data="${WINE_POC_DATA:-$HOME/Library/Application Support/GE-Proton macOS Wine PoC}"
mkdir -p "$data/prefixes/$variant" "$data/logs/$variant"
data="$(cd "$data" && pwd -P)"
export WINEPREFIX="$data/prefixes/$variant"
export XDG_CACHE_HOME="$data/cache/$variant"
export XDG_DATA_HOME="$data/state/$variant"
mkdir -p "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
export WINELOADER="$root/$variant/bin/wine"
export WINESERVER="$root/$variant/bin/wineserver"
export PATH="$root/$variant/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINE_D3D_CONFIG
unset STEAM_COMPAT_TRANSCODED_MEDIA_PATH STEAM_COMPAT_DATA_PATH
unset MEDIACONV_VIDEO_DUMP_FILE MEDIACONV_VIDEO_TRANSCODED_FILE MEDIACONV_BLANK_VIDEO_FILE
export WINEDLLOVERRIDES='winemenubuilder.exe=d'
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES LD_LIBRARY_PATH
# Wine opens MoltenVK by its SONAME; resolve it inside this runtime package.
export DYLD_FALLBACK_LIBRARY_PATH="$root/deps/lib:/usr/lib"
export WINEDEBUG="${POC_WINEDEBUG:-+timestamp,+pid,+tid,+loaddll,+quartz,+dmo,+wmvcore}"
log="$data/logs/$variant/$(date +%Y%m%d-%H%M%S)-$$.log"
echo "Prefix: $WINEPREFIX"
echo "Log: $log"
cd "$(dirname "$game")"
exec /usr/bin/arch -x86_64 "$WINELOADER" "$game" "$@" > "$log" 2>&1
