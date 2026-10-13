#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Download, verify and extract the CrossOver sources, then apply the media port.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
port="$POC_CROSSOVER_PORT"
archive="$port/$POC_CROSSOVER_ARCHIVE"
source_dir="$port/sources/wine"
if test -e "$source_dir"; then
  echo "Existing source directory: $source_dir. Keep it, or move it before preparing a fresh tree." >&2
  exit 2
fi
python3 "$POC_PROJECT/scripts/crossover/fetch-source.py" --archive "$archive"
mkdir -p "$port"
tar -xzf "$archive" -C "$port" sources/wine
cd "$source_dir"
# A fixed identity keeps the import commits independent of the user's git config.
commit() { git -c user.name='GE macOS PoC' -c user.email='poc@localhost' -c commit.gpgsign=false commit -q -m "$1"; }
git init -q
git checkout -q -b codex/crossover-media-fix
git add .
commit 'Import official CrossOver 26.3.0 source'
git apply "$POC_PROJECT/patches/crossover/crossover-26.3-media.patch"
git apply "$POC_PROJECT/patches/wine-ge/quartz-preserve-window-size.patch"
git apply "$POC_PROJECT/patches/wine-ge/mpeg-audio-wave-format.patch"
git apply "$POC_PROJECT/patches/wine-ge/command-line-append.patch"
git apply "$POC_PROJECT/patches/wine-ge/vkd3d-partial-varyings.patch"
git apply "$POC_PROJECT/patches/wine-ge/dbghelp-dwarf-divisor.patch"
git apply "$POC_PROJECT/patches/wine-ge/sechost-device-notify-handle.patch"
git apply "$POC_PROJECT/patches/wine-ge/stale-present-rect.patch"
git apply "$POC_PROJECT/patches/wine-ge/opengl-flush-flags.patch"
git apply "$POC_PROJECT/patches/wine-ge/macos-fullscreen-surface.patch"
git apply "$POC_PROJECT/patches/wine-ge/wow64-present-rect.patch"
python3 "$POC_PROJECT/scripts/source-notices.py" --source "$source_dir" --patch "$POC_PROJECT/patches/crossover/crossover-26.3-media.patch" --patch "$POC_PROJECT/patches/wine-ge/quartz-preserve-window-size.patch" --patch "$POC_PROJECT/patches/wine-ge/mpeg-audio-wave-format.patch" --patch "$POC_PROJECT/patches/wine-ge/command-line-append.patch" --patch "$POC_PROJECT/patches/wine-ge/vkd3d-partial-varyings.patch" --patch "$POC_PROJECT/patches/wine-ge/dbghelp-dwarf-divisor.patch" --patch "$POC_PROJECT/patches/wine-ge/sechost-device-notify-handle.patch" --patch "$POC_PROJECT/patches/wine-ge/stale-present-rect.patch" --patch "$POC_PROJECT/patches/wine-ge/opengl-flush-flags.patch" --patch "$POC_PROJECT/patches/wine-ge/macos-fullscreen-surface.patch" --patch "$POC_PROJECT/patches/wine-ge/wow64-present-rect.patch"
git add .
commit 'Port GE multimedia rework and macOS playback fixes'
echo "Prepared CrossOver source: $source_dir"
