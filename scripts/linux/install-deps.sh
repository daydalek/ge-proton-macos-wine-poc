#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Ubuntu 24.04 amd64 build and software-rendered validation prerequisites.
set -euo pipefail
test "$(uname -s)" = Linux
test "$(dpkg --print-architecture)" = amd64
sudo -n apt-get update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential clang lld libclang-rt-18-dev git cmake ninja-build pkg-config bison flex \
  autoconf automake libtool gettext curl ca-certificates xz-utils file patchelf \
  libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev libxcursor-dev \
  libxinerama-dev libxcomposite-dev libxfixes-dev libxxf86vm-dev \
  libfreetype-dev libfontconfig-dev libgnutls28-dev libasound2-dev libpulse-dev \
  libudev-dev libusb-1.0-0-dev libdbus-1-dev libgl-dev libegl-dev libvulkan-dev \
  libwayland-dev wayland-protocols libxkbcommon-dev libxkbregistry-dev libosmesa6-dev libpcap-dev \
  libsdl2-dev libunwind-dev zlib1g-dev xvfb xauth mesa-utils mesa-vulkan-drivers vulkan-tools \
  pulseaudio pulseaudio-utils dbus-daemon fonts-liberation fonts-noto-cjk
