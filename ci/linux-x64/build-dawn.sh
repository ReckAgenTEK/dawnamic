#!/usr/bin/env bash
set -Eeuo pipefail

source_directory=${DAWN_SOURCE_DIR:-/workspace/modules/dawn}
target_id=${DAWN_TARGET_ID:-linux-x64}
output_directory=${DAWN_OUTPUT_DIR:-/workspace/out/$target_id}
build_type=${DAWN_BUILD_TYPE:-Release}
jobs=${DAWN_BUILD_JOBS:-$(nproc)}

if [[ ! $target_id =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "invalid target ID: $target_id" >&2
    exit 2
fi

case $output_directory in
    /workspace/out/"$target_id") ;;
    *)
        echo "output directory must be /workspace/out/$target_id" >&2
        exit 2
        ;;
esac

case $(uname -m) in
    x86_64 | amd64) ;;
    *)
        echo "Dawn Linux build image supports x86_64 only" >&2
        exit 2
        ;;
esac

if [[ ! -f $source_directory/CMakeLists.txt ]]; then
    echo "Dawn source not found: $source_directory" >&2
    exit 2
fi

export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$source_directory" show -s --format=%ct HEAD)
export TZ=UTC
export LC_ALL=C.UTF-8
export ZERO_AR_DATE=1

build_root=$output_directory/build
stage_root=$output_directory/stage
shared_build=$build_root/shared
static_build=$build_root/static
shared_stage=$stage_root/shared
static_stage=$stage_root/static

rm -rf -- "$output_directory"
mkdir -p "$HOME" "$shared_build" "$static_build" "$shared_stage" "$static_stage"

configure_variant() {
    local linkage=$1
    local build_directory=$2
    local install_directory=$3
    local tint_tools=$4

    cmake \
        -S "$source_directory" \
        -B "$build_directory" \
        -G Ninja \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_INSTALL_PREFIX="$install_directory" \
        -DCMAKE_INSTALL_BINDIR=bin \
        -DCMAKE_INSTALL_INCLUDEDIR=include \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DDAWN_FETCH_DEPENDENCIES=ON \
        -DDAWN_ENABLE_INSTALL=ON \
        -DDAWN_ENABLE_PIC=ON \
        -DDAWN_BUILD_MONOLITHIC_LIBRARY="$linkage" \
        -DDAWN_ENABLE_D3D11=OFF \
        -DDAWN_ENABLE_D3D12=OFF \
        -DDAWN_ENABLE_METAL=OFF \
        -DDAWN_ENABLE_VULKAN=ON \
        -DDAWN_ENABLE_DESKTOP_GL=ON \
        -DDAWN_ENABLE_OPENGLES=ON \
        -DDAWN_ENABLE_NULL=ON \
        -DDAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF \
        -DDAWN_USE_X11=ON \
        -DDAWN_USE_WAYLAND=ON \
        -DDAWN_USE_GLFW=OFF \
        -DDAWN_USE_WINDOWS_UI=OFF \
        -DDAWN_BUILD_SAMPLES=OFF \
        -DDAWN_BUILD_TESTS=OFF \
        -DDAWN_BUILD_NODE_BINDINGS=OFF \
        -DDAWN_BUILD_PROTOBUF=OFF \
        -DDAWN_ENABLE_SWIFTSHADER=OFF \
        -DDAWN_BUILD_BENCHMARKS=OFF \
        -DDAWN_BUILD_FUZZERS=OFF \
        -DTINT_BUILD_CMD_TOOLS="$tint_tools" \
        -DTINT_BUILD_TINTD=OFF \
        -DTINT_ENABLE_INSTALL=OFF \
        -DTINT_BUILD_IR_BINARY=OFF \
        -DTINT_BUILD_GLSL_VALIDATOR=ON \
        -DTINT_BUILD_GLSL_WRITER=ON \
        -DTINT_BUILD_HLSL_WRITER=ON \
        -DTINT_BUILD_MSL_WRITER=ON \
        -DTINT_BUILD_NULL_WRITER=ON \
        -DTINT_BUILD_SPV_READER=ON \
        -DTINT_BUILD_SPV_WRITER=ON \
        -DTINT_BUILD_WGSL_READER=ON \
        -DTINT_BUILD_WGSL_WRITER=ON \
        -DTINT_BUILD_TESTS=OFF \
        -DTINT_BUILD_BENCHMARKS=OFF \
        -DTINT_BUILD_FUZZERS=OFF
}

configure_variant SHARED "$shared_build" "$shared_stage" ON
cmake \
    --build "$shared_build" \
    --parallel "$jobs" \
    --target webgpu_dawn tint_cmd_tint_cmd tint_cmd_info_cmd
cmake --install "$shared_build" --prefix "$shared_stage" --config "$build_type"

configure_variant STATIC "$static_build" "$static_stage" OFF
cmake \
    --build "$static_build" \
    --parallel "$jobs" \
    --target webgpu_dawn
cmake --install "$static_build" --prefix "$static_stage" --config "$build_type"

/usr/local/bin/package-dawn.sh
