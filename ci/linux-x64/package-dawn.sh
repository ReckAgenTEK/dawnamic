#!/usr/bin/env bash
set -Eeuo pipefail

source_directory=${DAWN_SOURCE_DIR:-/workspace/modules/dawn}
target_id=${DAWN_TARGET_ID:-linux-x64}
output_directory=${DAWN_OUTPUT_DIR:-/workspace/out/$target_id}
build_type=${DAWN_BUILD_TYPE:-Release}
base_image=${DAWN_BASE_IMAGE:-unknown}
package_snapshot=${DAWN_PACKAGE_SNAPSHOT:-unknown}
security_snapshot=${DAWN_SECURITY_SNAPSHOT:-}
archive_suffix=${DAWN_ARCHIVE_SUFFIX:-}

case $archive_suffix in
    '' | .repack) ;;
    *)
        echo "unsupported archive suffix: $archive_suffix" >&2
        exit 2
        ;;
esac

build_root=$output_directory/build
stage_root=$output_directory/stage
package_name=dawn-$target_id
package_root=$output_directory/package/$package_name
artifact_directory=$output_directory/artifacts
archive=$artifact_directory/$package_name.tar.zst$archive_suffix
archive_checksum=$archive.sha256

shared_build=$build_root/shared
shared_stage=$stage_root/shared
static_stage=$stage_root/static

for required in \
    "$shared_stage/lib/libwebgpu_dawn.so" \
    "$static_stage/lib/libwebgpu_dawn.a" \
    "$shared_build/tint" \
    "$shared_build/tint_info"; do
    if [[ ! -f $required ]]; then
        echo "required package output missing: $required" >&2
        exit 2
    fi
done

rm -rf -- "$output_directory/package"
rm -f -- "$archive" "$archive_checksum"
mkdir -p \
    "$package_root" \
    "$package_root/tools/bin" \
    "$package_root/licenses" \
    "$package_root/manifests" \
    "$artifact_directory"

cp -a "$shared_stage" "$package_root/shared"
cp -a "$static_stage" "$package_root/static"
rm -rf -- \
    "$package_root/shared/include/dawn/wire" \
    "$package_root/static/include/dawn/wire"
install -m 0755 "$shared_build/tint" "$package_root/tools/bin/tint"
install -m 0755 "$shared_build/tint_info" "$package_root/tools/bin/tint_info"

vulkan_headers=$source_directory/third_party/vulkan-headers/src/include
if [[ ! -d $vulkan_headers/vulkan || ! -d $vulkan_headers/vk_video ]]; then
    echo "fetched Vulkan-Headers include tree is missing: $vulkan_headers" >&2
    exit 2
fi
for variant in shared static; do
    cp -a "$vulkan_headers/vulkan" "$package_root/$variant/include/"
    cp -a "$vulkan_headers/vk_video" "$package_root/$variant/include/"
done

static_config=$package_root/static/lib/cmake/Dawn/DawnConfig.cmake
if [[ -f $static_config ]] && ! grep -q 'find_dependency(Threads)' "$static_config"; then
    sed -i \
        '/include *("${CMAKE_CURRENT_LIST_DIR}\/DawnTargets.cmake")/i include(CMakeFindDependencyMacro)\nfind_dependency(Threads)\n' \
        "$static_config"
fi
if [[ ! -f $static_config ]] || ! grep -q 'find_dependency(Threads)' "$static_config"; then
    echo "static Dawn CMake package could not be made self-contained: $static_config" >&2
    exit 2
fi

(
    cd "$source_directory"
    find . -type f \
        \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'LICENSE-*' \
           -o -iname 'COPYING' -o -iname 'COPYING.*' -o -iname 'NOTICE' \
           -o -iname 'NOTICE.*' -o -path '*/LICENSES/*' \) \
        -exec cp --parents -t "$package_root/licenses" -- {} +
)

source_revision=$(git -C "$source_directory" rev-parse HEAD)
source_epoch=$(git -C "$source_directory" show -s --format=%ct HEAD)
compiler_version=$(clang --version)
compiler_version=${compiler_version%%$'\n'*}
cmake_version=$(cmake --version)
cmake_version=${cmake_version%%$'\n'*}

python3 - \
    "$package_root/manifests/build-info.json" \
    "$target_id" \
    "$base_image" \
    "$build_type" \
    "$source_revision" \
    "$source_epoch" \
    "$compiler_version" \
    "$cmake_version" \
    "$package_snapshot" \
    "$security_snapshot" <<'PY'
import json
import sys

(
    output,
    target,
    base_image,
    build_type,
    source_revision,
    source_epoch,
    compiler,
    cmake,
    package_snapshot,
    security_snapshot,
) = sys.argv[1:]

with open(output, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "schema_version": 1,
            "target": target,
            "architecture": "x86_64",
            "container_base_image": base_image,
            "build_type": build_type,
            "dawn_revision": source_revision,
            "source_date_epoch": int(source_epoch),
            "compiler": compiler,
            "cmake": cmake,
            "package_repository_snapshot": package_snapshot,
            "security_repository_snapshot": security_snapshot,
            "variants": {
                "shared": "shared/lib/libwebgpu_dawn.so",
                "static": "static/lib/libwebgpu_dawn.a",
            },
            "tools": ["tools/bin/tint", "tools/bin/tint_info"],
            "backends": ["Vulkan", "OpenGL", "OpenGL ES", "Null"],
            "window_systems": ["X11", "Wayland via Vulkan"],
        },
        stream,
        indent=2,
        sort_keys=True,
    )
    stream.write("\n")
PY

cat > "$package_root/manifests/runtime-loaded-libraries.txt" <<'EOF'
Dawn loads these backend libraries at runtime; they are intentionally not bundled:
- Vulkan: libvulkan.so.1
- OpenGL/OpenGL ES: libEGL.so
- X11: libX11.so.6
- X11/XCB interoperability when available: libX11-xcb.so.1

GPU drivers, libc, C++ runtime, and distribution system libraries remain target dependencies.
Wayland presentation is supported by the Vulkan backend at this Dawn revision.
EOF

cat > "$package_root/manifests/sdk-dependencies.txt" <<'EOF'
- Public WebGPU C/C++ headers and pinned Vulkan-Headers are included in each variant.
- Defining Vulkan XCB/Xlib platform macros additionally requires target system X11/XCB headers.
- Static manual-link consumers also need the target C++ runtime, Threads, and dl.
- Packaged static DawnConfig.cmake resolves Threads and exports Dawn's remaining link interface.
- Select exactly one CMake prefix: shared/ or static/. Their dawn::webgpu_dawn targets cannot be merged.
EOF

if command -v pacman >/dev/null 2>&1; then
    pacman -Q | LC_ALL=C sort > "$package_root/manifests/system-packages.txt"
elif command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package}\t${Version}\n' \
        | LC_ALL=C sort > "$package_root/manifests/system-packages.txt"
else
    echo "supported system package database not found" >&2
    exit 2
fi

runtime_needed=$package_root/manifests/elf-needed-libraries.txt
runtime_needed_unsorted=$runtime_needed.unsorted
: > "$runtime_needed_unsorted"
while IFS= read -r -d '' candidate; do
    if patchelf --print-needed "$candidate" >/dev/null 2>&1; then
        relative=${candidate#"$package_root/"}
        while IFS= read -r dependency; do
            printf '%s: %s\n' "$relative" "$dependency" >> "$runtime_needed_unsorted"
        done < <(patchelf --print-needed "$candidate")
    fi
done < <(find "$package_root/shared" "$package_root/tools" -type f -print0)
LC_ALL=C sort -u "$runtime_needed_unsorted" > "$runtime_needed"
rm -f -- "$runtime_needed_unsorted"

cat > "$package_root/README.md" <<EOF
# Dawn redistributable SDK: $target_id

This archive contains one Dawn source revision built twice for the target container ABI.

- \`shared/\`: shared \`libwebgpu_dawn.so\`, public C/C++ and Vulkan headers, and matching CMake package metadata.
- \`static/\`: static \`libwebgpu_dawn.a\`, public C/C++ and Vulkan headers, and matching CMake package metadata.
- \`tools/bin/\`: Tint shader translation and inspection CLIs (\`tint\`, \`tint_info\`).
- \`licenses/\`: Dawn and fetched dependency redistribution notices.
- \`manifests/\`: source/build identity, runtime dependencies, SDK dependencies, and checksums.

Enabled Dawn backends: Vulkan, desktop OpenGL, OpenGL ES, and Null. X11 surfaces are enabled. Wayland surfaces are enabled through Vulkan; this Dawn revision does not support Wayland presentation through its EGL OpenGL backend.

Tests, benchmarks, fuzzers, samples, Node bindings, Tint language server, and SwiftShader are not redistributable SDK payloads and are not built.
EOF

contents_manifest=$package_root/manifests/contents.sha256
(
    cd "$package_root"
    find . -type f ! -path './manifests/contents.sha256' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum > "$contents_manifest"
)

tar \
    --sort=name \
    --mtime="@$source_epoch" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --use-compress-program='zstd -19 -T1' \
    -cf "$archive" \
    -C "$output_directory/package" \
    "$package_name"

(
    cd "$artifact_directory"
    sha256sum "$(basename "$archive")" > "$(basename "$archive_checksum")"
)
cat "$archive_checksum"
