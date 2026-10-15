# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared environment for the build/run scripts. Source it; do not execute it.
#
#   source "$(dirname "$0")/lib/common.sh"
#
# Paths come from the repository location, never from the machine that last ran
# the scripts. Everything below can be overridden through the environment:
#   POC_WORK_DIR                  work tree (default: <repo>/work)
#   POC_JOBS                      parallel make jobs (default: logical CPU count)
#   POC_MACOSX_DEPLOYMENT_TARGET  oldest macOS for host binaries (configs/build.env)
#   PKG_CONFIG, CMAKE             explicit tool paths (default: search PATH,
#                                 Homebrew on Apple Silicon/Intel, MacPorts)

if test -n "${POC_COMMON_LOADED:-}"; then return 0; fi
POC_COMMON_LOADED=1

POC_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

poc_die() { echo "error: $*" >&2; exit 1; }
poc_note() { echo "==> $*" >&2; }

# Load KEY=VALUE defaults without overriding values already in the environment.
poc_load_defaults() {
  local file="$1" key value
  while IFS='=' read -r key value || test -n "$key"; do
    case "$key" in ''|'#'*) continue ;; esac
    if test -z "${!key+set}"; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
    fi
  done < "$file"
}
poc_load_defaults "$POC_PROJECT/configs/build.env"

test "$(uname -s)" = Darwin || poc_die "these scripts target macOS hosts only."

POC_WORK="${POC_WORK_DIR:-$POC_PROJECT/work}"
case "$POC_WORK" in /*) ;; *) POC_WORK="$PWD/$POC_WORK" ;; esac
POC_ROOT="$POC_WORK/poc"
POC_TOOLS="$POC_ROOT/tools"
POC_DEPS="$POC_ROOT/stage/deps-x64"
POC_LLVM_MINGW="$POC_TOOLS/$POC_LLVM_MINGW_DIR"
POC_SOURCE_ROOT="${POC_SOURCE_ROOT:-$POC_WORK/repro}"
case "$POC_SOURCE_ROOT" in /*) ;; *) POC_SOURCE_ROOT="$PWD/$POC_SOURCE_ROOT" ;; esac
POC_CROSSOVER_PORT="$POC_WORK/crossover-port"

POC_JOBS="${POC_JOBS:-$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
case "$POC_JOBS" in ''|*[!0-9]*|0) poc_die "POC_JOBS must be a positive integer" ;; esac
case "$POC_MACOSX_DEPLOYMENT_TARGET" in ''|*[!0-9.]*|.*|*.) poc_die "invalid deployment target" ;; esac

# clang, cmake and FFmpeg's configure all honour this variable.
export MACOSX_DEPLOYMENT_TARGET="$POC_MACOSX_DEPLOYMENT_TARGET"
POC_HOST_CC="/usr/bin/clang -arch x86_64 -mmacosx-version-min=$POC_MACOSX_DEPLOYMENT_TARGET"
POC_HOST_CXX="/usr/bin/clang++ -arch x86_64 -mmacosx-version-min=$POC_MACOSX_DEPLOYMENT_TARGET"

# Find a host tool in PATH or the usual package-manager prefixes.
poc_find_tool() {
  local name dir
  for name in "$@"; do
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for dir in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
      if test -x "$dir/$name"; then echo "$dir/$name"; return 0; fi
    done
  done
  return 1
}

poc_require_clt() {
  /usr/bin/xcrun --show-sdk-path >/dev/null 2>&1 ||
    poc_die "Xcode Command Line Tools are missing; run: xcode-select --install"
}

poc_require_rosetta() {
  if test "$(uname -m)" = arm64 && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    poc_die "Rosetta 2 is required; run: softwareupdate --install-rosetta --agree-to-license"
  fi
}

poc_require_path() {
  test -e "$1" || poc_die "missing $1${2:+ ($2)}"
}

# Fill the POC_CROSSOVER_PATCHES array with the ordered, project-relative
# CrossOver patch series (comments and blank lines skipped).
poc_load_crossover_patches() {
  local line
  POC_CROSSOVER_PATCHES=()
  while IFS= read -r line || test -n "$line"; do
    case "$line" in ''|'#'*) continue ;; esac
    test -f "$POC_PROJECT/$line" || poc_die "missing patch $line (configs/crossover-patch-series.txt)"
    POC_CROSSOVER_PATCHES+=("$line")
  done < "$POC_PROJECT/configs/crossover-patch-series.txt"
  test "${#POC_CROSSOVER_PATCHES[@]}" -gt 0 || poc_die "empty CrossOver patch series"
}

# PATH and tool variables for configure/make. Only the project tools, the
# directories of the detected cmake/pkg-config and the system directories are
# visible, so random user tools cannot leak into the build.
poc_setup_build_env() {
  poc_require_clt
  PKG_CONFIG="${PKG_CONFIG:-$(poc_find_tool pkg-config pkgconf)}" ||
    poc_die "pkg-config not found; install it (brew install pkgconf / port install pkgconfig) or set PKG_CONFIG"
  PKG_CONFIG="$(command -v "$PKG_CONFIG")" || poc_die "PKG_CONFIG is not executable"
  test -x "$PKG_CONFIG" || poc_die "PKG_CONFIG is not executable"
  export PKG_CONFIG
  local extra
  extra="$(dirname "$PKG_CONFIG")"
  if CMAKE="${CMAKE:-$(poc_find_tool cmake)}"; then
    CMAKE="$(command -v "$CMAKE")" || poc_die "CMAKE is not executable"
    test -x "$CMAKE" || poc_die "CMAKE is not executable"
    export CMAKE
    case ":$extra:" in *":$(dirname "$CMAKE"):"*) ;; *) extra="$extra:$(dirname "$CMAKE")" ;; esac
  fi
  POC_PYTHON="${PYTHON:-$(poc_find_tool python3)}" || poc_die "Python 3.9 or later is required"
  POC_PYTHON="$(command -v "$POC_PYTHON")" || poc_die "Python interpreter is not executable"
  "$POC_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else "Python 3.9 or later is required")' || poc_die "unsupported Python interpreter"
  export POC_PYTHON
  extra="$extra:$(dirname "$POC_PYTHON")"
  export PATH="$POC_TOOLS/bin:$POC_LLVM_MINGW/bin:$extra:/usr/bin:/bin:/usr/sbin:/sbin"
  unset WINEDLLPATH WINEPREFIX WINELOADER WINESERVER WINEARCH
  unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES LD_LIBRARY_PATH
}

# Environment for building Wine against the project dependencies.
poc_setup_wine_build_env() {
  poc_setup_build_env
  poc_require_path "$POC_TOOLS/bin/bison" "run scripts/build-deps.sh"
  poc_require_path "$POC_TOOLS/bin/autoconf" "run scripts/build-deps.sh"
  poc_require_path "$POC_LLVM_MINGW/bin/lld-link" "run scripts/build-deps.sh"
  poc_require_path "$POC_DEPS/lib/pkgconfig" "run scripts/build-deps.sh"
  export BISON_PKGDATADIR="$POC_TOOLS/share/bison"
  export M4="$POC_TOOLS/bin/m4"
  export CC="$POC_HOST_CC"
  export CXX="$POC_HOST_CXX"
  export PKG_CONFIG_LIBDIR="$POC_DEPS/lib/pkgconfig:$POC_DEPS/share/pkgconfig"
  export PKG_CONFIG_PATH=''
  export CPPFLAGS="-I$POC_DEPS/include"
  export LDFLAGS="-L$POC_DEPS/lib -Wl,-rpath,$POC_DEPS/lib"
}
