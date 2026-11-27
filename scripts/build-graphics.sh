#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="${EMU_WORK:?Set EMU_WORK to the build directory}"
src="$work/source"
prefix="$work/vulkan"
stage="$work/stage/graphics"
common="$stage/common"
vulkan="$common/vulkan/linux-x86_64"
angle="$common/ANGLE/linux-x86_64/lib"
gles="$common/swiftshader/linux-x86_64/lib"
jobs=${JOBS:-$(nproc)}
python=${PYTHON:-python3}
export CC=/usr/bin/clang-21 CXX=/usr/bin/clang++-21
if ! printf '#include <xcb/shm.h>\n' | "$CXX" -x c++ -fsyntax-only -; then
    printf 'SwiftShader requires the libxcb-shm0-dev package.\n' >&2
    exit 1
fi
"$python" scripts/inputs.py graphics "$src"
mkdir -p "$gles" "$angle" "$vulkan/icds" "$vulkan/layers"
export CCACHE_DIR="$work/ccache"
mkdir -p "$CCACHE_DIR"
cmake_options=(
    -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.10
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix"
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DUPDATE_DEPS=OFF -DBUILD_TESTS=OFF
)

apply_one() {
    patch --batch -p1 -d "$src/$1" < "$root/patches/$2.patch"
}

build_prefix() {
    name=$1
    shift
    cmake -S "$src/$name" -B "$work/$name" "${cmake_options[@]}" "$@"
    cmake --build "$work/$name" --parallel "$jobs"
    cmake --install "$work/$name" --strip
}

cmake -S "$src/swiftshader-gles" -B "$work/swiftshader-gles" "${cmake_options[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$work/swiftshader-gles" --parallel "$jobs" --target libEGL libGLESv2 libGLES_CM
install -s -m 755 "$work/swiftshader-gles"/lib{EGL,GLESv2,GLES_CM}.so "$gles/"

apply_one swiftshader-vulkan swiftshader-llvm-signals-cstdint
apply_one swiftshader-vulkan swiftshader-lru-cache-cstdint
cmake -S "$src/swiftshader-vulkan" -B "$work/swiftshader-vulkan" "${cmake_options[@]}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_FLAGS=-Wno-deprecated-declarations \
    -DSWIFTSHADER_BUILD_TESTS=OFF -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF -DSPIRV_WERROR=OFF
cmake --build "$work/swiftshader-vulkan" --parallel "$jobs" --target vk_swiftshader
install -s -m 755 "$work/swiftshader-vulkan/libvk_swiftshader.so" "$vulkan/icds/"
install -m 644 "$work/swiftshader-vulkan/Linux/vk_swiftshader_icd.json" "$vulkan/icds/"
cp "$vulkan/icds"/{libvk_swiftshader.so,vk_swiftshader_icd.json} "$angle/"

build_prefix loader-headers
build_prefix loader -DVULKAN_HEADERS_INSTALL_DIR="$prefix"
install -m 755 "$prefix/lib/libvulkan.so" "$vulkan/libvulkan.so"
install -m 755 "$prefix/lib/libvulkan.so" "$angle/libvulkan.so"

apply_one angle angle-shader-vars-stdint
apply_one angle/third_party/abseil-cpp angle-abseil-str-format-stdint
apply_one angle/third_party/vulkan_memory_allocator angle-vma-include-cstdio
"$python" "$src/gn/build/gen.py" --no-last-commit-position --out-path="$work/gn"
# Pin the version header because the source archive contains no Git metadata.
cat > "$work/gn/last_commit_position.h" <<'GN_VERSION'
#pragma once
#define LAST_COMMIT_POSITION_NUM 1968
#define LAST_COMMIT_POSITION "1968 (0725d782)"
GN_VERSION
ninja -C "$work/gn" -j "$jobs" gn
# ANGLE's DEPS supplies this argument when checked out using gclient.
printf 'generate_location_tags = false\n' > "$src/angle/build/config/gclient_args.gni"
mkdir -p "$work/angle"
cat > "$work/angle/args.gn" <<ARGS
is_debug = false
is_component_build = false
use_custom_libcxx = false
use_sysroot = false
clang_use_chrome_plugins = false
clang_base_path = "/usr/lib/llvm-21"
angle_enable_swiftshader = false
angle_standalone = false
angle_build_all = false
angle_use_custom_libvulkan = false
angle_build_vulkan_system_info = false
treat_warnings_as_errors = false
use_lld = false
use_gold = false
ARGS
"$work/gn/gn" gen "$work/angle" --root="$src/angle"
(
    if [[ -n "${EMU_HOST_OVERLAY:-}" ]]; then
        export CPATH="$EMU_HOST_OVERLAY/usr/include/x86_64-linux-gnu${CPATH:+:$CPATH}"
        export LIBRARY_PATH="$EMU_HOST_OVERLAY/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
    fi
    ninja -C "$work/angle" -j "$jobs" libEGL.so libGLESv2.so libshadertranslator.so
)
install -s -m 755 "$work/angle"/lib{EGL,GLESv2,shadertranslator}.so "$angle/"

build_prefix SPIRV-Headers
build_prefix Vulkan-Headers
apply_one glslang glslang-spvbuilder-cstdint
ln -s "$src/SPIRV-Tools" "$src/glslang/External/spirv-tools"
build_prefix glslang -DBUILD_EXTERNAL=ON -DENABLE_OPT=ON -DGLSLANG_TESTS=OFF \
    -DSPIRV-Headers_SOURCE_DIR="$src/SPIRV-Headers" -DSPIRV_SKIP_TESTS=ON
install -m 755 "$prefix/bin/glslangValidator" "$vulkan/"
build_prefix Vulkan-Utility-Libraries
build_prefix jsoncpp -DBUILD_SHARED_LIBS=OFF -DJSONCPP_WITH_TESTS=OFF
apply_one robin-hood-hashing robin-hood-include-cstdint
build_prefix robin-hood-hashing -DRH_STANDALONE_PROJECT=OFF
build_prefix valijson -Dvalijson_BUILD_TESTS=OFF
apply_one VulkanTools vulkan-api-dump-retain-dispatch-key
build_prefix VulkanTools -DBUILD_APIDUMP=ON -DBUILD_MONITOR=ON -DBUILD_SCREENSHOT=ON \
    -DBUILD_VIA=OFF -DBUILD_LAYERMGR=OFF -DBUILD_WERROR=OFF
build_prefix Vulkan-ValidationLayers -DBUILD_WERROR=OFF
for library in "$prefix"/lib/libVkLayer*.so; do
    install -m 755 "$library" "$vulkan/layers/"
done
while IFS= read -r -d '' manifest; do
    install -m 644 "$manifest" "$vulkan/layers/"
done < <(find "$prefix/share/vulkan" -name VkLayer\*.json -type f -print0)

mkdir -p "$work/bin"
ln -s /usr/bin/llvm-config-21 "$work/bin/llvm-config"
export PATH="$work/bin:$PATH"
meson setup "$work/mesa" "$src/mesa" --buildtype=release --wrap-mode=nodownload \
    --prefix="$work/mesa-install" --libdir=lib \
    -Dplatforms=x11 -Dgallium-drivers=llvmpipe -Dvulkan-drivers=swrast \
    -Dllvm=enabled -Dshared-llvm=enabled -Dglvnd=disabled -Degl=enabled \
    -Dgles1=enabled -Dgles2=enabled -Dopengl=true -Dgbm=enabled -Dglx=dri \
    -Dvideo-codecs=[]
meson compile -C "$work/mesa" -j "$jobs"
meson install -C "$work/mesa" --strip
mesa_lib="$work/mesa-install/lib"
llvmpipe="$common/gles_llvmpipe"
mkdir -p "$llvmpipe/dri" "$llvmpipe/gbm"
install -m 755 "$mesa_lib"/lib{EGL,GLESv2,gbm,GL}.so "$mesa_lib"/libgallium-*.so "$llvmpipe/"
install -m 755 "$mesa_lib/libGLESv1_CM.so" "$llvmpipe/libGLES_CM.so"
install -m 755 "$mesa_lib"/dri/{kms_swrast_dri,swrast_dri,libdril_dri}.so "$llvmpipe/dri/"
install -m 755 "$mesa_lib/gbm/dri_gbm.so" "$llvmpipe/gbm/"
install -m 755 "$mesa_lib/libvulkan_lvp.so" "$vulkan/icds/"
install -m 644 "$work/mesa-install/share/vulkan/icd.d/lvp_icd.x86_64.json" "$vulkan/icds/lvp_icd.json"
sed -i 's|"library_path"[[:space:]]*:[[:space:]]*"[^"]*"|"library_path": "./libvulkan_lvp.so"|' \
    "$vulkan/icds/lvp_icd.json"

mkdir -p "$stage/licenses"
for package in "$src"/*; do
    directory="$stage/licenses/${package##*/}"
    for notice in "$package"/{LICENSE*,COPYING*,NOTICE*}; do
        if [[ -f "$notice" ]]; then
            mkdir -p "$directory"
            cp -L -- "$notice" "$directory/"
        fi
    done
done
install -D -m 644 "$src/mesa/docs/license.rst" "$stage/licenses/mesa/license.rst"
cp -a "$src/mesa/licenses" "$stage/licenses/mesa/"
mkdir -p out/components
tar -C "$work/stage" -I 'zstd -T2 -3' -cf "$work/graphics.tar.zst" graphics
mv -f "$work/graphics.tar.zst" out/components/graphics.tar.zst
