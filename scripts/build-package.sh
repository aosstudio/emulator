#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="${EMU_WORK:?Set EMU_WORK to the build directory}"
src="$work/source"
parts="$work/parts"
qemu="$src/external/qemu"
build="$work/build"
prefix="$work/host-libraries"
prebuilts="$src/prebuilts/android-emulator-build"
jobs=${JOBS:-$(nproc)}
python=${PYTHON:-python3}
host_lib=/usr/lib/x86_64-linux-gnu
overlay=${EMU_HOST_OVERLAY:-}

mkdir -p "$parts"
for component in qt netsim firmware graphics-angle graphics-swiftshader-gles \
    graphics-swiftshader-vulkan graphics-vulkan graphics-mesa; do
    archive="out/components/$component.tar.zst"
    test -s "$archive"
    tar --zstd -xf "$archive" -C "$parts"
done
"$python" scripts/inputs.py core "$src"
export CC=/usr/bin/clang-21 CXX=/usr/bin/clang++-21
export GIT_CEILING_DIRECTORIES="$src"

for change in optional-bundled-demo-assets guard-tcmalloc-packaging linux-util-link-item \
    host-third-party-build-notices protobuf-utf8-range-notice option-system-lavapipe-runtime \
    glibc-strlcpy system-shared-libuuid system-shared-libxml2 \
    memory-watch-stdint linux-native-driver-cxx-runtime qemu-device-tree-source-libfdt \
    netsim-os-utils-stdint headless-pulse-const-signatures \
    qemu-guard-optional-tcmalloc-hooks system-shared-libunwind gfxstream-honor-angle-parser-option; do
    patch --batch -p1 -d "$qemu" < "$root/patches/$change.patch"
done
patch --batch -p1 -d "$src/external/webrtc/third_party" < patches/webrtc-local-cmake-notices.patch

mkdir -p "$prefix" "$work/media"
(
    cd "$src/host-libraries/x264"
    ./configure --prefix="$prefix" --enable-pic --extra-cflags=-fPIC \
        --disable-asm --disable-cli --enable-static
    make -j "$jobs"
    make install
)
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
(
    cd "$work/media"
    "$src/host-libraries/ffmpeg/configure" --prefix="$prefix" --cc="$CC" \
        --pkg-config-flags=--static --extra-cflags=-O3 --extra-libs=-ldl \
        --enable-static --disable-shared --disable-doc --disable-programs --enable-gpl \
        --disable-asm --disable-avdevice --disable-filters --enable-avresample \
        --enable-libx264 --enable-libvpx --disable-xlib --enable-pic --disable-autodetect \
        --disable-network --disable-muxers --enable-muxer=gif,webm,webm_chunk,webm_dash_manifest \
        --disable-demuxers --enable-demuxer=matroska,mov,webm_dash_manifest \
        --disable-protocols --enable-protocol=file --disable-encoders \
        --enable-encoder=gif,libvpx_vp9,vorbis --disable-decoders \
        --enable-decoder=gif,libvpx_vp9,vorbis,hevc,h264
    grep -qx '#define CONFIG_LIBVPX_VP9_ENCODER 1' config.h
    grep -qx '#define CONFIG_LIBVPX_VP9_DECODER 1' config.h
    make -j "$jobs"
    make install
)
mkdir "$work/pixman"
(
    cd "$work/pixman"
    "$src/host-libraries/pixman/configure" --prefix="$prefix" --enable-static \
        --disable-shared --with-pic --disable-gtk
    make -C pixman -j "$jobs"
    make -C pixman install
)

mkdir -p "$prebuilts/qt" "$prebuilts/common"
ln -s "$parts/qt" "$prebuilts/qt/linux-x86_64"
ln -s "$parts/qt" "$prebuilts/qt/linux-x86_64-nowebengine"
cp -a "$parts/graphics/common/." "$prebuilts/common/"
ln -s "$src/external/angle/include" "$prebuilts/common/ANGLE/linux-x86_64/include"
mkdir -p "$prebuilts/common/netsim/linux-x86_64"
install -m 755 "$parts/netsim/netsimd" "$prebuilts/common/netsim/linux-x86_64/"
mkdir -p "$prebuilts/common/virglrenderer/linux-x86_64/include"
ln -s "$src/external/virglrenderer/src" "$prebuilts/common/virglrenderer/linux-x86_64/include/virgl"

media_libs() {
    name=$1
    shift
    target="$prebuilts/common/$name/linux-x86_64"
    mkdir -p "$target/lib"
    ln -s "$prefix/include" "$target/include"
    for lib in "$@"; do
        ln -s "$prefix/lib/lib$lib.a" "$target/lib/"
    done
}
media_libs x264 x264
media_libs ffmpeg avutil avformat avcodec swresample avfilter swscale
vpx="$prebuilts/common/libvpx/linux-x86_64"
vpx_root=/usr
if [[ -n "$overlay" && -f "$overlay$host_lib/libvpx.a" ]]; then
    vpx_root="$overlay/usr"
fi
mkdir -p "$vpx/lib"
ln -s "$vpx_root/include" "$vpx/include"
ln -s "$vpx_root/lib/x86_64-linux-gnu/libvpx.a" "$vpx/lib/"
unwind="$prebuilts/common/libunwind/linux-x86_64"
unwind_headers=/usr/include/x86_64-linux-gnu
if [[ -n "$overlay" && -f "$overlay$unwind_headers/libunwind.h" ]]; then
    unwind_headers="$overlay$unwind_headers"
fi
mkdir -p "$unwind"
ln -s "$unwind_headers" "$unwind/include"
mkdir -p "$prebuilts/qemu-android-deps/linux-x86_64/lib"
ln -s "$prefix/lib/libpixman-1.a" "$prebuilts/qemu-android-deps/linux-x86_64/lib/"
mkdir -p "$prebuilts/qemu-android-deps/linux-x86_64/include"
ln -s "$prefix/include/pixman-1" "$prebuilts/qemu-android-deps/linux-x86_64/include/"
e2fs="$prebuilts/common/e2fsprogs/linux-x86_64"
mkdir -p "$e2fs"/{lib,include,sbin}
ln -s /usr/include/uuid "$e2fs/include/uuid"
ln -s "$host_lib/libuuid.a" "$e2fs/lib/"
for program in e2fsck fsck.ext4 mkfs.ext4 resize2fs tune2fs; do
    ln -s "/usr/sbin/$program" "$e2fs/sbin/"
done
install -m 644 "$parts/firmware/roms/"* "$qemu/pc-bios/"
gallium=("$parts/graphics/common/gles_llvmpipe"/libgallium-*.so)
[[ ${#gallium[@]} -eq 1 && -f "${gallium[0]}" ]]

cmake -S "$qemu" -B "$build" -GNinja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10 -DAOSP_ROOT="$src" \
    -DCMAKE_MODULE_PATH="$qemu/android/build/cmake" \
    -DCMAKE_PROJECT_INCLUDE="$root/scripts/linux-system-deps.cmake" \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DOPTION_BAZEL=OFF -DOPTION_BUNDLE_DEMO_ASSETS=OFF -DOPTION_MINBUILD=ON \
    -DUSE_ANGLE_SHADER_PARSER=OFF -DOPTION_SYSTEM_LAVAPIPE_RUNTIME=ON \
    -DLLVMPIPE_GALLIUM_LIBRARY="${gallium[0]##*/}" \
    -DOPTION_CRASHUPLOAD=NONE -DQTWEBENGINE=OFF -DWEBRTC=OFF \
    -DOPTION_SDK_TOOLS_REVISION=37.3.10 -DOPTION_SDK_TOOLS_BUILD_NUMBER=0
cmake --build "$build" --parallel "$jobs" --target \
    emulator emulator-check qemu-img mksdcard crashreport crashpad_handler qsn \
    nimble_bridge emulator_make_ext4fs android-emu-shared gfxstream_backend image_converter \
    qemu-system-x86_64 qemu-system-x86_64-headless \
    qemu-system-aarch64 qemu-system-aarch64-headless
product="$work/install/emulator"
cmake --install "$build" --prefix "$product" --component Unspecified --strip
install -m 755 "$parts/qt/lib/libQt6OpenGLAndroidEmu.so.6" "$product/lib64/qt/lib/"
mkdir -p "$product/licenses"
install -m 644 locks/{sources,graphics,firmware}.json "$product/licenses/"
for component in qt netsim graphics firmware; do
    cp -a "$parts/$component/licenses" "$product/licenses/$component"
done
install -m 644 "$parts/netsim/LICENSE" "$product/licenses/netsim/LICENSE"
sed -i 's/^Pkg.Desc=.*/Pkg.Desc=AOSStudio Emulator/' "$product/source.properties"
"$python" scripts/package.py "$product"
