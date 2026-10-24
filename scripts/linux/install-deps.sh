#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Ubuntu 24.04 amd64 build and optional software-rendered validation prerequisites.
set -euo pipefail
case "${1:-}" in
  '') runtime=1 ;;
  --compile-only) runtime=0 ;;
  *) echo 'Usage: install-deps.sh [--compile-only]' >&2; exit 2 ;;
esac
test "$(uname -s)" = Linux
test "$(dpkg --print-architecture)" = amd64

# Hosted runners can inherit a slow Azure Ubuntu mirror. Retain signed Ubuntu
# repositories and third-party sources while using the canonical archive in CI.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  sudo -n python3 - <<'PY'
from pathlib import Path
paths = [Path('/etc/apt/sources.list')]
paths += list(Path('/etc/apt/sources.list.d').glob('*.list'))
paths += list(Path('/etc/apt/sources.list.d').glob('*.sources'))
for path in paths:
    if not path.is_file():
        continue
    original = path.read_text()
    current = original.replace('http://azure.archive.ubuntu.com/ubuntu',
                               'https://archive.ubuntu.com/ubuntu')
    current = current.replace('https://azure.archive.ubuntu.com/ubuntu',
                              'https://archive.ubuntu.com/ubuntu')
    if current != original:
        path.write_text(current)
        print('Ubuntu archive mirror updated:', path)
PY
fi
apt_options=(-o Acquire::Retries=3 -o Acquire::http::Timeout=45
  -o Acquire::https::Timeout=45 -o Acquire::http::Dl-Limit=0
  -o Acquire::https::Dl-Limit=0 -o DPkg::Lock::Timeout=120)
packages=(
  build-essential clang lld libclang-rt-18-dev git cmake ninja-build pkg-config bison flex
  autoconf automake libtool gettext curl ca-certificates xz-utils file patchelf
  libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev libxcursor-dev
  libxinerama-dev libxcomposite-dev libxfixes-dev libxxf86vm-dev
  libfreetype-dev libfontconfig-dev libgnutls28-dev libasound2-dev libpulse-dev
  libudev-dev libusb-1.0-0-dev libdbus-1-dev libgl-dev libegl-dev libvulkan-dev
  libwayland-dev wayland-protocols libxkbcommon-dev libxkbregistry-dev libosmesa6-dev libpcap-dev
  libsdl2-dev libunwind-dev zlib1g-dev
)
if [ "$runtime" = 1 ]; then
  packages+=(xvfb xauth mesa-utils mesa-vulkan-drivers vulkan-tools
    pulseaudio pulseaudio-utils dbus-daemon fonts-liberation fonts-noto-cjk)
fi
sudo -n apt-get "${apt_options[@]}" update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y --no-install-recommends "${packages[@]}"
