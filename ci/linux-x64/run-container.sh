#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 6 )); then
    echo "usage: $0 <target> <dockerfile> <base-image> <build-type> <package-snapshot> <security-snapshot>" >&2
    exit 2
fi

target=$1
dockerfile_relative=$2
base_image=$3
build_type=$4
package_snapshot=$5
security_snapshot=$6

if [[ ! $target =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "invalid target name: $target" >&2
    exit 2
fi

case $dockerfile_relative in
    ci/linux-x64/docker/*) ;;
    *)
        echo "dockerfile must be under ci/linux-x64/docker" >&2
        exit 2
        ;;
esac
if [[ $dockerfile_relative == *..* ]]; then
    echo "dockerfile path cannot contain '..'" >&2
    exit 2
fi

case $build_type in
    Debug | Release | RelWithDebInfo | MinSizeRel) ;;
    *)
        echo "unsupported CMake build type: $build_type" >&2
        exit 2
        ;;
esac

if [[ -z $base_image || $base_image =~ [[:space:]] ]]; then
    echo "invalid base image: $base_image" >&2
    exit 2
fi
if [[ ! $package_snapshot =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2}|[0-9]{8}T[0-9]{6}Z)$ ]]; then
    echo "invalid package snapshot: $package_snapshot" >&2
    exit 2
fi
if [[ -n $security_snapshot && ! $security_snapshot =~ ^([0-9]{4}/[0-9]{2}/[0-9]{2}|[0-9]{8}T[0-9]{6}Z)$ ]]; then
    echo "invalid security snapshot: $security_snapshot" >&2
    exit 2
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/../.." && pwd)
dockerfile="$repository_root/$dockerfile_relative"
dawn_source="$repository_root/modules/dawn"

if [[ ! -f $dockerfile ]]; then
    echo "dockerfile not found: $dockerfile_relative" >&2
    exit 2
fi

if [[ ! -f $dawn_source/CMakeLists.txt ]]; then
    echo "Dawn submodule is not initialized at modules/dawn" >&2
    exit 2
fi

case $(uname -m) in
    x86_64 | amd64) ;;
    *)
        echo "Linux container builds require an x86_64 host" >&2
        exit 2
        ;;
esac

run_id=${GITHUB_RUN_ID:-local}
run_attempt=${GITHUB_RUN_ATTEMPT:-0}
image="dawn-builder:${target}-${run_id}-${run_attempt}"
jobs=${DAWN_BUILD_JOBS:-$(nproc)}

docker build \
    --pull \
    --platform linux/amd64 \
    --build-arg "BASE_IMAGE=$base_image" \
    --build-arg "PACKAGE_SNAPSHOT=$package_snapshot" \
    --build-arg "SECURITY_SNAPSHOT=$security_snapshot" \
    --file "$dockerfile" \
    --tag "$image" \
    "$script_directory"

run_in_image() {
    local entrypoint=${1:-}
    local -a arguments=(
        run
        --rm
        --init
        --platform linux/amd64
        --user "$(id -u):$(id -g)"
        --env "DAWN_TARGET_ID=$target"
        --env "DAWN_BASE_IMAGE=$base_image"
        --env "DAWN_BUILD_TYPE=$build_type"
        --env "DAWN_BUILD_JOBS=$jobs"
        --env "DAWN_PACKAGE_SNAPSHOT=$package_snapshot"
        --env "DAWN_SECURITY_SNAPSHOT=$security_snapshot"
        --env DAWN_SOURCE_DIR=/workspace/modules/dawn
        --env "DAWN_OUTPUT_DIR=/workspace/out/$target"
        --env HOME=/tmp/dawn-home
        --mount "type=bind,source=$repository_root,target=/workspace"
        --workdir /workspace
    )
    if [[ -n $entrypoint ]]; then
        arguments+=(--entrypoint "$entrypoint")
    fi
    arguments+=("$image")
    docker "${arguments[@]}"
}

run_in_image
run_in_image /usr/local/bin/verify-package.sh
