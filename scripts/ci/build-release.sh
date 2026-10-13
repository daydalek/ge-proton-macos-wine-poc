#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail
project="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$project"
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64 || { echo 'Requires an arm64 macOS runner.' >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
test "$major" -ge 27 || { echo 'Requires a macOS 27+ runner.' >&2; exit 1; }
/usr/bin/arch -x86_64 /usr/bin/true || { echo 'Install Rosetta 2 before running this workflow.' >&2; exit 1; }
export POC_MACOSX_DEPLOYMENT_TARGET=27.0
: "${POC_WORK_DIR:?Set a fresh isolated POC_WORK_DIR}"
test ! -e "$POC_WORK_DIR" || { echo 'Build work directory must be fresh.' >&2; exit 1; }
command -v cmake >/dev/null
command -v pkg-config >/dev/null || command -v pkgconf >/dev/null
bash scripts/build-deps.sh
python3 scripts/prepare.py
bash scripts/build-wine.sh baseline
bash scripts/build-wine.sh media
bash tools/probes/build-probes.sh
package="$POC_WORK_DIR/package"
python3 scripts/package.py --output "$package"
python3 scripts/static-check.py --package "$package" --max-minimum-macos 27.0
python3 scripts/ci/make-release.py --package "$package" --output "${POC_RELEASE_DIR:-$project/outputs/release}"

# The runtime release counter is independent of the upstream Wine version/tag.
: "${GITHUB_RUN_NUMBER:?Set GITHUB_RUN_NUMBER for monotonically increasing runtime versions}"
RUNTIME_VERSION="11.0.$((GITHUB_RUN_NUMBER + 1))"
python3 scripts/ci/build-libraries.py --version "$RUNTIME_VERSION" --output "${POC_RELEASE_DIR:-$project/outputs/release}"
