#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
usage: local-build.sh [--repack-check] [all|target-list|json-array]

Examples:
  ci/linux-x64/local-build.sh archlinux-x64
  ci/linux-x64/local-build.sh ubuntu-26.04-x64,debian-13-x64
  ci/linux-x64/local-build.sh --repack-check '["archlinux-x64","steamos-x64"]'

Build archives and checksums remain under out/<target>/artifacts/. Logs,
aggregate checksums, and the last resolved matrix remain under out/local-build/.
EOF
}

repack_check=0
selection=all
selection_set=0

while (( $# > 0 )); do
    case $1 in
        --repack-check)
            repack_check=1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            if (( $# > 1 )); then
                echo "only one target selection argument is supported" >&2
                exit 2
            fi
            if (( $# == 1 )); then
                selection=$1
                selection_set=1
            fi
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if (( selection_set )); then
                echo "only one target selection argument is supported" >&2
                exit 2
            fi
            selection=$1
            selection_set=1
            ;;
    esac
    shift
done

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/../.." && pwd)
resolver=$script_directory/resolve-targets.py
container_runner=$script_directory/run-container.sh
local_output=$repository_root/out/local-build
log_directory=$local_output/logs
resolved_matrix=$local_output/resolved-targets.json

for required in "$resolver" "$container_runner"; do
    if [[ ! -x $required ]]; then
        echo "required executable not found: $required" >&2
        exit 2
    fi
done

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required for local Dawn builds" >&2
    exit 2
fi
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not available to this user" >&2
    exit 2
fi

mkdir -p "$log_directory"
"$resolver" "$selection" > "$resolved_matrix"

mapfile -d '' -t target_fields < <(
    python3 - "$resolved_matrix" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    matrix = json.load(stream)

for target in matrix["include"]:
    for key in (
        "id",
        "dockerfile",
        "base_image",
        "build_type",
        "package_snapshot",
        "security_snapshot",
    ):
        sys.stdout.buffer.write(target[key].encode("utf-8") + b"\0")
PY
)

if (( ${#target_fields[@]} == 0 || ${#target_fields[@]} % 6 != 0 )); then
    echo "resolver returned an invalid target matrix" >&2
    exit 2
fi

run_in_target_image() {
    local image=$1
    local entrypoint=$2
    local target=$3
    local base_image=$4
    local build_type=$5
    local package_snapshot=$6
    local security_snapshot=$7
    local archive_suffix=${8:-}

    docker run \
        --rm \
        --init \
        --platform linux/amd64 \
        --user "$(id -u):$(id -g)" \
        --env "DAWN_TARGET_ID=$target" \
        --env "DAWN_BASE_IMAGE=$base_image" \
        --env "DAWN_BUILD_TYPE=$build_type" \
        --env "DAWN_PACKAGE_SNAPSHOT=$package_snapshot" \
        --env "DAWN_SECURITY_SNAPSHOT=$security_snapshot" \
        --env "DAWN_ARCHIVE_SUFFIX=$archive_suffix" \
        --env DAWN_SOURCE_DIR=/workspace/modules/dawn \
        --env "DAWN_OUTPUT_DIR=/workspace/out/$target" \
        --env HOME=/tmp/dawn-home \
        --mount "type=bind,source=$repository_root,target=/workspace" \
        --workdir /workspace \
        --entrypoint "$entrypoint" \
        "$image"
}

for (( index=0; index<${#target_fields[@]}; index+=6 )); do
    target=${target_fields[index]}
    dockerfile=${target_fields[index + 1]}
    base_image=${target_fields[index + 2]}
    build_type=${target_fields[index + 3]}
    package_snapshot=${target_fields[index + 4]}
    security_snapshot=${target_fields[index + 5]}
    image=dawn-builder:${target}-local-0
    archive=$repository_root/out/$target/artifacts/dawn-$target.tar.zst
    archive_checksum=$archive.sha256
    log=$log_directory/$target.log

    {
        echo "target: $target"
        echo "base image: $base_image"
        echo "build type: $build_type"
        echo "package snapshot: $package_snapshot"
        echo "security snapshot: $security_snapshot"

        GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=0 \
            "$container_runner" \
                "$target" \
                "$dockerfile" \
                "$base_image" \
                "$build_type" \
                "$package_snapshot" \
                "$security_snapshot"

        if [[ ! -s $archive || ! -s $archive_checksum ]]; then
            echo "expected archive/checksum was not created: $archive" >&2
            exit 1
        fi

        if (( repack_check )); then
            before=$(sha256sum "$archive")
            before=${before%% *}

            run_in_target_image \
                "$image" \
                /workspace/ci/linux-x64/package-dawn.sh \
                "$target" \
                "$base_image" \
                "$build_type" \
                "$package_snapshot" \
                "$security_snapshot" \
                .repack

            repack_archive=$archive.repack
            if [[ ! -s $repack_archive || ! -s $repack_archive.sha256 ]]; then
                echo "deterministic repack output is missing: $repack_archive" >&2
                exit 1
            fi
            after=$(sha256sum "$repack_archive")
            after=${after%% *}
            if [[ $before != "$after" ]]; then
                echo "deterministic repack failed: $before != $after" >&2
                exit 1
            fi
            rm -f -- "$repack_archive" "$repack_archive.sha256"
            echo "deterministic repack: $after"
        fi

        echo "archive: $archive"
    } 2>&1 | tee "$log"
done

artifact_manifest=$local_output/artifacts.sha256
artifact_manifest_temp=$(mktemp "$local_output/.artifacts.sha256.XXXXXX")
while IFS= read -r archive; do
    archive_hash=$(sha256sum "$archive")
    archive_hash=${archive_hash%% *}
    printf '%s  %s\n' "$archive_hash" "${archive#"$repository_root/"}" \
        >> "$artifact_manifest_temp"
done < <(
    find "$repository_root/out" \
        -mindepth 3 \
        -maxdepth 3 \
        -type f \
        -path '*/artifacts/*.tar.zst' \
        -print \
        | LC_ALL=C sort
)
mv -- "$artifact_manifest_temp" "$artifact_manifest"

echo "resolved targets: $resolved_matrix"
echo "logs: $log_directory"
echo "artifact hashes: $artifact_manifest"
