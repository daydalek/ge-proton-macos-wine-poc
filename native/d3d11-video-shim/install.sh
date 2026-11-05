#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Install or remove the d3d11 video shim next to a Windows application.
#
#   install.sh --dir <app-dir> --arch x64|x32 [--source <build-out>] [--dll <shim.dll>]
#   install.sh --dir <app-dir> --remove
#
# Install renames the application's existing d3d11.dll (usually DXVK's) to
# d3d11_original.dll and drops the shim in as d3d11.dll.  With --source the
# shim is taken from <build-out>/<arch>/d3d11.dll (default: build.sh output).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
source "$here/../../scripts/lib/common.sh"

app_dir=""
arch=""
source_dir=""
dll=""
original=""
remove=0

usage() {
    sed -n '2,11p' "$0"
    exit "${1:-1}"
}

while test $# -gt 0; do
    case "$1" in
        --dir) app_dir="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --source) source_dir="$2"; shift 2 ;;
        --dll) dll="$2"; shift 2 ;;
        --original) original="$2"; shift 2 ;;
        --remove) remove=1; shift ;;
        -h|--help) usage 0 ;;
        *) poc_die "unknown argument: $1" ;;
    esac
done

test -n "$app_dir" || usage
test -d "$app_dir" || poc_die "not a directory: $app_dir"

shim_dll="$app_dir/d3d11.dll"
orig_dll="$app_dir/d3d11_original.dll"

# A shim dll contains the forwarder name as plain ASCII in its export table.
is_shim() {
    test -f "$1" && LC_ALL=C rg -q 'd3d11_original' "$1" 2>/dev/null
}

if test "$remove" = 1; then
    if test -f "$orig_dll"; then
        is_shim "$shim_dll" && rm -f "$shim_dll"
        test -f "$shim_dll" || mv "$orig_dll" "$shim_dll"
        poc_note "removed shim from $app_dir"
    else
        poc_note "no shim installed in $app_dir"
    fi
    exit 0
fi

if test -z "$dll"; then
    case "$arch" in
        x64|x32) ;;
        *) poc_die "--arch x64|x32 is required without --dll" ;;
    esac
    source_dir="${source_dir:-$POC_WORK/d3d11-video-shim}"
    dll="$source_dir/$arch/d3d11.dll"
fi
poc_require_path "$dll" "run native/d3d11-video-shim/build.sh"
is_shim "$dll" || poc_die "$dll does not look like the shim"

if test -f "$orig_dll"; then
    poc_note "shim already installed; replacing d3d11.dll"
elif test -f "$shim_dll"; then
    if is_shim "$shim_dll"; then
        poc_die "broken state: $shim_dll is the shim but d3d11_original.dll is missing"
    fi
    mv "$shim_dll" "$orig_dll"
    poc_note "renamed existing d3d11.dll -> d3d11_original.dll"
elif test -n "$original"; then
    cp "$original" "$orig_dll"
    poc_note "copied $original -> d3d11_original.dll"
else
    poc_die "no d3d11.dll in $app_dir; pass --original <path-to-DXVK-d3d11.dll>"
fi

cp "$dll" "$shim_dll"
poc_note "installed shim as $shim_dll"
