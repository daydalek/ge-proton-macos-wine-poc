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
poc_load_crossover_patches
notice_args=()
for patch_name in "${POC_CROSSOVER_PATCHES[@]}"; do
  git apply "$POC_PROJECT/$patch_name"
  notice_args+=(--patch "$POC_PROJECT/$patch_name")
done
python3 "$POC_PROJECT/scripts/source-notices.py" --source "$source_dir" "${notice_args[@]}"
git add .
commit 'Port GE multimedia rework and macOS playback fixes'
echo "Prepared CrossOver source: $source_dir"
