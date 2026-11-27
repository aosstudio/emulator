#!/usr/bin/env bash
set -euo pipefail

packages=(ca-certificates curl make zstd)
case "${1:?Supply a build target}" in
    qt)
        packages+=(build-essential cmake ninja-build pkg-config libdbus-1-dev libegl-dev
            libfontconfig1-dev libfreetype-dev libgl-dev libpng-dev libtiff-dev
            libvulkan-dev libwebp-dev libx11-dev libx11-xcb-dev libxcb-cursor-dev
            libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev libxcb-randr0-dev
            libxcb-render-util0-dev libxcb-shape0-dev libxcb-shm0-dev libxcb-sync-dev
            libxcb-util-dev libxcb-xfixes0-dev libxcb-xkb-dev libxkbcommon-x11-dev
            libxrender-dev zlib1g-dev)
        ;;
    netsim)
        packages+=(bubblewrap jq)
        ;;
    graphics)
        packages+=(bison build-essential clang-21 cmake flex git glslang-tools
            libdrm-dev libelf-dev libpci-dev libunwind-dev libvulkan-dev libwayland-dev
            libx11-xcb-dev libxcb-dri3-dev libxcb-glx0-dev libxcb-present-dev
            libxcb-randr0-dev libxfixes-dev libxrandr-dev libxshmfence-dev
            llvm-21-dev meson ninja-build patch pkg-config python3-mako
            spirv-tools xvfb zlib1g-dev)
        ;;
    firmware)
        packages+=(binutils build-essential gcc-multilib nasm perl python3)
        ;;
    package)
        packages+=(bison build-essential clang-21 cmake e2fsprogs flex
            libegl-dev libgl-dev libglib2.0-dev libglu1-mesa-dev libpulse-dev
            libunwind-dev libvpx-dev libx11-dev libx11-xcb-dev libxcb1-dev
            libxi-dev libxinerama-dev libxml2-dev libxrandr-dev ninja-build
            patch pkg-config uuid-dev zlib1g-dev)
        ;;
    verify)
        packages+=(bubblewrap busybox-static cpio e2fsprogs file libdrm2 libegl1
            libglib2.0-0t64 libgl1 libllvm21 libpci3 libpulse0 libunwind8 libvpx12 libwayland-client0
            libx11-6 libxi6 libxml2-16 libxrandr2 libxshmfence1)
        ;;
    *)
        printf 'Unknown build target %s\n' "$1" >&2
        exit 2
        ;;
esac
apt-get update
apt-get install --yes --no-install-recommends "${packages[@]}"
