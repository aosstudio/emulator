#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="${EMU_WORK:?Set EMU_WORK to the build directory}"
python=${PYTHON:-python3}
jobs=${JOBS:-$(nproc)}
"$python" scripts/inputs.py netsim "$work/source"
"$python" scripts/inputs.py netsim_bootstrap "$work"
"$python" scripts/inputs.py netsim_dist "$work/dist"

cares_version=1.34.9
cares=c-ares-$cares_version
tar -xzf "$work/dist/$cares.tar.gz" -C "$work"
cp -a "$work/source/registry/modules/c-ares/$cares_version/overlay/." "$work/$cares/"

mkdir -p "$work/jdk" "$work/home" "$work/stage/netsim"
tar -xzf "$work/jdk.tar.gz" -C "$work/jdk"
chmod 755 "$work/bazel"

go_archive=go1.22.4.linux-amd64.tar.gz
go_sha=$(jq -r '.netsim_bootstrap.go.sha256' locks/sources.json)
go_size=$(stat -c %s "$work/dist/$go_archive")
jq -n --arg file "$go_archive" --arg sha "$go_sha" --argjson size "$go_size" \
    '[{version:"go1.22.4",stable:true,files:[{filename:$file,os:"linux",arch:"amd64",version:"go1.22.4",sha256:$sha,size:$size,kind:"archive"}]}]' \
    > "$work/dist/versions.json"
cat > "$work/downloader.cfg" <<'INNER'
rewrite (go\.dev|golang\.google\.cn)/dl/\?mode=json&include=all http://127.0.0.1:39837/versions.json
rewrite static\.rust-lang\.org/dist/(?:2026-03-26/)?((?:rustc|cargo|rust-std|rustfmt|clippy|llvm-tools)-1\.94\.1-x86_64-unknown-linux-gnu\.tar\.xz) http://127.0.0.1:39837/$1
INNER

distdirs=(--distdir=/work/dist)
for folder in "$work"/dist/*/; do
    if [[ -f "$folder/download" ]]; then
        path=${folder%/}
        distdirs+=("--distdir=/work/dist/${path##*/}")
    fi
done

# The inner shell expands the mirror process ID.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --new-session --clearenv \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache \
    --ro-bind-try /etc/alternatives /etc/alternatives --proc /proc --dev /dev \
    --bind "$work" /work --ro-bind "$work/source" /work/source \
    --bind "$work/tmp" /tmp --chdir /work/source/tools/netsim \
    --setenv HOME /work/home --setenv PATH /usr/bin:/bin \
    --setenv JAVA_HOME /work/jdk --setenv LC_ALL C.UTF-8 -- \
    /bin/bash -c '
      set -euo pipefail
      python3 -m http.server 39837 --bind 127.0.0.1 --directory /work/dist >/work/mirror.log 2>&1 &
      mirror_pid=$!
      trap '\''kill "$mirror_pid" 2>/dev/null || true'\'' EXIT
      /work/bazel --batch --output_user_root=/work/bazel-state \
        --output_base=/work/bazel-output --nosystem_rc --nohome_rc --noworkspace_rc "$@"
    ' shell build \
    --registry=file:///work/source/tools/netsim/registry \
    --registry=file:///work/source/build/bazel/registry \
    --registry=file:///work/source/registry "${distdirs[@]}" \
    --lockfile_mode=off --downloader_config=/work/downloader.cfg \
    --override_module="c-ares=/work/$cares" \
    --incompatible_autoload_externally=+cc_library,+cc_binary,+cc_test,+proto_library,+objc_library,+cc_proto_library,+sh_binary,+sh_test,+sh_library \
    --host_platform=@host_platform//:host \
    --platforms=@host_platform//:host \
    --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1 \
    --@rules_rust//rust/settings:experimental_use_allocator_libraries_with_mangled_symbols \
    --@rules_rust//rust/settings:extra_rustc_env=RUSTC_BOOTSTRAP=1 \
    --@rules_rust//rust/settings:extra_exec_rustc_env=RUSTC_BOOTSTRAP=1 \
    --@rules_python//python/config_settings:bootstrap_impl=script \
    --define=grpc_no_xds=true --define=GRPC_ALLOW_EXCEPTIONS=0 --define=absl=1 \
    --experimental_convenience_symlinks=ignore \
    --spawn_strategy=processwrapper-sandbox,local --jobs="$jobs" -c opt \
    --workspace_status_command='python3 scripts/version_stamp.py' \
    //src/daemon:netsimd

mapfile -t binaries < <(find "$work/bazel-output/execroot" -type f -path '*/bin/src/daemon/netsimd')
test "${#binaries[@]}" -eq 1
stage="$work/stage/netsim"
install -m 0755 "${binaries[0]}" "$stage/netsimd"
"$stage/netsimd" --version
install -m 644 "$work/source/tools/netsim/LICENSE" "$stage/LICENSE"
mkdir -p "$stage/licenses"
for repository in abseil-cpp boringssl c-ares grpc protobuf zlib; do
    location=$(readlink "$work/bazel-output/external/$repository+")
    source="$work${location#/work}"
    for notice in "$source"/{LICENSE*,COPYING*,NOTICE*,COPYRIGHT*}; do
        if [[ -f "$notice" ]]; then
            install -D -m 644 "$notice" "$stage/licenses/$repository/${notice##*/}"
        fi
    done
done
install -D -m 644 "$work/source/third_party/libslirp/COPYRIGHT" \
    "$stage/licenses/libslirp/COPYRIGHT"
install -D -m 644 "$work/source/packages/modules/Nfc/libnfc-nci/tools/casimir/LICENSE" \
    "$stage/licenses/casimir/LICENSE"
while IFS= read -r -d '' directory; do
    crate=${directory##*/}
    notice_dir="$stage/licenses/$crate"
    for notice in "$directory"/{LICENSE*,COPYING*,NOTICE*,UNLICENSE*}; do
        if [[ -f "$notice" ]]; then
            mkdir -p "$notice_dir"
            cp -L -- "$notice" "$notice_dir/"
        fi
    done
done < <(find "$work/source/external/rust" "$work/source/third_party/rust" -name Cargo.toml -printf '%h\0')
mkdir -p out/components
tar -C "$work/stage" -I 'zstd -T2 -3' -cf "$work/netsim.tar.zst" netsim
mv -f "$work/netsim.tar.zst" out/components/netsim.tar.zst
