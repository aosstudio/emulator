#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="${EMU_WORK:?Set EMU_WORK to the build directory}"
src="$work/source"
stage="$work/stage/firmware"
roms="$stage/roms"
notices="$stage/licenses"
jobs=${JOBS:-$(nproc)}
"${PYTHON:-python3}" scripts/inputs.py firmware "$src"
mkdir -p "$roms" "$notices"
qemu="$src/qemu"
option="$work/optionrom"
mkdir -p "$option/pc-bios/optionrom"
cat > "$option/config-host.mak" <<CONFIG
SRC_PATH=$qemu
BUILD_DIR=$option
CC=gcc
CPP=gcc -E
AS=as
LD=ld
OBJCOPY=objcopy
PYTHON=python3
CFLAGS=-O2 -std=gnu99
CFLAGS_NOPIE=-fno-pie
LDFLAGS_NOPIE=-no-pie
LD_I386_EMULATION=elf_i386
CONFIG
make -C "$option/pc-bios/optionrom" -f "$qemu/pc-bios/optionrom/Makefile" \
    -j "$jobs" kvmvapic.bin linuxboot.bin linuxboot_dma.bin multiboot.bin
install -m 644 "$option/pc-bios/optionrom"/{kvmvapic,linuxboot,linuxboot_dma,multiboot}.bin "$roms/"
install -m 644 "$qemu/COPYING" "$notices/QEMU-GPL-2.0.txt"

bios="$src/seabios"
printf '1.17.0\n' > "$bios/.version"
build="$work/seabios"
mkdir -p "$build"
printf 'CONFIG_QEMU=y\nCONFIG_ROM_SIZE=256\n' > "$build/.config"
make -C "$bios" PYTHON=python3 OUT="$build/" KCONFIG_CONFIG="$build/.config" olddefconfig
make -C "$bios" PYTHON=python3 OUT="$build/" KCONFIG_CONFIG="$build/.config" -j "$jobs"
test "$(stat -c %s "$build/bios.bin")" -eq $((256 * 1024))
# QEMU names the default and fallback BIOS separately.
install -m 644 "$build/bios.bin" "$roms/bios-256k.bin"
install -m 644 "$build/bios.bin" "$roms/bios.bin"
for video in cirrus stdvga virtio; do
    build="$work/vgabios-$video"
    mkdir -p "$build"
    {
        printf 'CONFIG_QEMU=y\nCONFIG_BUILD_VGABIOS=y\nCONFIG_ROM_SIZE=0\n'
        case "$video" in
            cirrus) printf 'CONFIG_VGA_CIRRUS=y\n' ;;
            stdvga) printf 'CONFIG_VGA_BOCHS=y\nCONFIG_VGA_BOCHS_STDVGA=y\n' ;;
            virtio)
                printf 'CONFIG_VGA_BOCHS=y\nCONFIG_VGA_BOCHS_STDVGA=y\n'
                printf 'CONFIG_OVERRIDE_PCI_ID=y\nCONFIG_VGA_VID=0x1af4\nCONFIG_VGA_DID=0x1050\n'
                ;;
        esac
    } > "$build/.config"
    make -C "$bios" PYTHON=python3 OUT="$build/" KCONFIG_CONFIG="$build/.config" olddefconfig
    make -C "$bios" PYTHON=python3 OUT="$build/" KCONFIG_CONFIG="$build/.config" -j "$jobs" "$build/vgabios.bin"
    install -m 644 "$build/vgabios.bin" "$roms/vgabios-$video.bin"
done
install -m 644 "$bios/COPYING" "$notices/SeaBIOS-COPYING"
install -m 644 "$bios/COPYING.LESSER" "$notices/SeaBIOS-COPYING.LESSER"

ipxe="$src/ipxe/src"
products=(1af41000 8086100e 808610d3)
rom_names=(virtio e1000 e1000e)
for architecture in bin bin-i386-efi bin-x86_64-efi; do
    suffix=efi
    if [[ "$architecture" = bin ]]; then suffix=rom; fi
    targets=()
    for product in "${products[@]}"; do targets+=("$architecture/$product.$suffix"); done
    make -C "$ipxe" -j "$jobs" NO_WERROR=1 CC='gcc -std=gnu11' CONFIG=qemu "${targets[@]}"
done
efi="$src/efirom-edk2/BaseTools/Source/C"
make -C "$efi/Common" -j "$jobs" ARCH=X64
make -C "$efi/EfiRom" -j "$jobs" ARCH=X64
for index in "${!products[@]}"; do
    product=${products[$index]}
    "$efi/bin/EfiRom" -f "0x${product:0:4}" -i "0x${product:4:4}" \
        -b "$ipxe/bin/$product.rom" -ec "$ipxe/bin-i386-efi/$product.efi" \
        -ec "$ipxe/bin-x86_64-efi/$product.efi" -o "$roms/efi-${rom_names[$index]}.rom"
done
for notice in COPYING COPYING.GPLv2 COPYING.UBDL; do
    install -m 644 "$src/ipxe/$notice" "$notices/iPXE-$notice"
done
install -m 644 "$src/efirom-edk2/License.txt" "$notices/EDK-II-License.txt"
[[ $(find "$roms" -maxdepth 1 -type f | wc -l) = 12 ]]
mkdir -p out/components
tar -C "$work/stage" -I 'zstd -T2 -3' -cf "$work/firmware.tar.zst" firmware
mv -f "$work/firmware.tar.zst" out/components/firmware.tar.zst
