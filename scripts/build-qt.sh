#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="${EMU_WORK:?Set EMU_WORK to the build directory}"
sources="$work/source/qt"
install="$work/stage/qt"
overlay=${EMU_HOST_OVERLAY:-}
host_lib=/usr/lib/x86_64-linux-gnu
jobs=${JOBS:-$(nproc)}
"${PYTHON:-python3}" scripts/inputs.py qt "$sources"
common=(
    -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install"
    -DCMAKE_C_COMPILER=/usr/bin/clang-21 -DCMAKE_CXX_COMPILER=/usr/bin/clang++-21
    -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF
    -DCMAKE_FIND_PACKAGE_TARGETS_GLOBAL=ON
)
prefix=$install
if [[ -n "$overlay" ]]; then
    prefix="$install;$overlay/usr"
    export LD_LIBRARY_PATH="$overlay$host_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# Keep Qt's event dispatch independent of the GUI process's QEMU GLib loop.
cmake -S "$sources/qtbase" -B "$work/qtbase" "${common[@]}" \
    -DCMAKE_PREFIX_PATH="$prefix" -DQT_LIBINFIX=AndroidEmu \
    -DFEATURE_xcb=ON -DFEATURE_glib=OFF
cmake --build "$work/qtbase" --parallel "$jobs"
cmake --install "$work/qtbase" --strip
for module in qtsvg qtimageformats; do
    options=()
    if [[ "$module" = qtimageformats ]]; then
        options+=(-DINPUT_tiff=system -DINPUT_webp=system)
        if [[ -n "$overlay" ]]; then
            options+=(-DCMAKE_DISABLE_FIND_PACKAGE_WebP=ON)
        fi
    fi
    cmake -S "$sources/$module" -B "$work/$module" "${common[@]}" \
        -DCMAKE_PREFIX_PATH="$prefix" "${options[@]}"
    cmake --build "$work/$module" --parallel "$jobs"
    cmake --install "$work/$module" --strip
done
for tool in moc uic rcc; do
    "$install/libexec/$tool" --version
done
test -f "$install/include/QtGui/6.5.3/QtGui/private/qkeymapper_p.h"
test -f "$install/plugins/platforms/libqxcbAndroidEmu.so"
mkdir -p "$install/licenses"
for module in qtbase qtsvg qtimageformats; do
    cp -a "$sources/$module/LICENSES" "$install/licenses/$module"
done
while IFS=$'\t' read -r lib package; do
    lib_dir=$host_lib
    doc_dir=/usr/share/doc
    if [[ -n "$overlay" && -e "$overlay$host_lib/$lib" ]]; then
        lib_dir=$overlay$host_lib
        doc_dir=$overlay/usr/share/doc
    fi
    install -m 644 "$lib_dir/$lib" "$install/lib/$lib"
    install -m 644 "$doc_dir/$package/copyright" "$install/licenses/$package.txt"
done < locks/qt-runtime.tsv
mkdir -p out/components
tar -C "$work/stage" -I 'zstd -T2 -3' -cf "$work/qt.tar.zst" qt
mv -f "$work/qt.tar.zst" out/components/qt.tar.zst
