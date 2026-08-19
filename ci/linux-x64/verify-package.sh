#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

fail() {
    echo "package verification failed: $*" >&2
    exit 1
}

target_id=${DAWN_TARGET_ID:-linux-x64}
output_directory=${DAWN_OUTPUT_DIR:-/workspace/out/$target_id}
package_name=dawn-$target_id
artifact_directory=$output_directory/artifacts
archive=$artifact_directory/$package_name.tar.zst
archive_checksum=$archive.sha256
verification_directory=$output_directory/verification
work_directory=$verification_directory/work

if [[ ! $target_id =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    fail "invalid target ID: $target_id"
fi

case $output_directory in
    /workspace/out/"$target_id") ;;
    *) fail "output directory must be /workspace/out/$target_id" ;;
esac

for command in ar awk clang clang++ cmake cmp find ninja python3 readelf readlink sha256sum sort tar uniq zstd; do
    command -v "$command" >/dev/null || fail "required command is unavailable: $command"
done

shopt -s nullglob
archives=("$artifact_directory"/*.tar.zst)
if (( ${#archives[@]} != 1 )) || [[ ${archives[0]} != "$archive" ]]; then
    fail "expected exactly one archive at $archive"
fi
[[ -s $archive ]] || fail "archive is empty: $archive"
[[ -s $archive_checksum ]] || fail "archive checksum is missing: $archive_checksum"
(
    cd "$artifact_directory"
    sha256sum --check --strict "$(basename "$archive_checksum")"
) || fail "archive checksum validation failed"

rm -rf -- "$verification_directory"
mkdir -p "$work_directory/extracted" "$work_directory/smoke-source"
trap 'rm -rf -- "$work_directory"' EXIT

zstd --test --quiet "$archive" || fail "zstd integrity check failed"

member_list=$work_directory/archive-members.txt
tar \
    --use-compress-program='zstd -d -q' \
    --list \
    --file "$archive" > "$member_list" || fail "tar listing failed"
[[ -s $member_list ]] || fail "archive contains no members"

while IFS= read -r member; do
    [[ -n $member ]] || fail "archive contains an empty member name"
    member=${member%/}
    case $member in
        "$package_name" | "$package_name"/*) ;;
        *) fail "archive member escapes package root: $member" ;;
    esac

    IFS=/ read -r -a components <<< "$member"
    for component in "${components[@]}"; do
        case $component in
            '' | . | ..) fail "archive member has unsafe path component: $member" ;;
        esac
    done
done < "$member_list"

duplicate_members=$(sort "$member_list" | uniq -d)
[[ -z $duplicate_members ]] || fail "archive contains duplicate members"

tar \
    --use-compress-program='zstd -d -q' \
    --extract \
    --no-same-owner \
    --no-same-permissions \
    --directory "$work_directory/extracted" \
    --file "$archive" || fail "tar extraction failed"

package_root=$work_directory/extracted/$package_name
[[ -d $package_root && ! -L $package_root ]] || fail "package root is missing or unsafe"

while IFS= read -r -d '' link; do
    resolved=$(readlink -m -- "$link")
    case $resolved in
        "$package_root" | "$package_root"/*) ;;
        *) fail "symlink escapes package root: ${link#"$package_root"/}" ;;
    esac
done < <(find "$package_root" -type l -print0)

contents_manifest=$package_root/manifests/contents.sha256
[[ -s $contents_manifest ]] || fail "contents checksum manifest is missing"
(
    cd "$package_root"
    sha256sum --check --strict manifests/contents.sha256
) || fail "contents checksum validation failed"

manifest_paths=$work_directory/manifest-paths.txt
: > "$manifest_paths"
while IFS= read -r line; do
    [[ $line =~ ^[0-9a-f]{64}\ \ \./[^[:cntrl:]]+$ ]] \
        || fail "malformed contents checksum entry"
    printf '%s\n' "${line:66}" >> "$manifest_paths"
done < "$contents_manifest"

actual_paths=$work_directory/actual-paths.txt
(
    cd "$package_root"
    find . -type f ! -path './manifests/contents.sha256' -print | sort
) > "$actual_paths"
sort "$manifest_paths" -o "$manifest_paths"
cmp --silent "$manifest_paths" "$actual_paths" \
    || fail "contents checksum manifest does not describe every regular file exactly once"

required_relative_paths=(
    shared/lib/libwebgpu_dawn.so
    static/lib/libwebgpu_dawn.a
    shared/include/webgpu/webgpu.h
    shared/include/webgpu/webgpu_cpp.h
    shared/include/dawn/webgpu.h
    shared/include/dawn/webgpu_cpp.h
    shared/include/dawn/native/DawnNative.h
    shared/include/dawn/native/VulkanBackend.h
    shared/include/vulkan/vulkan.h
    static/include/webgpu/webgpu.h
    static/include/webgpu/webgpu_cpp.h
    static/include/dawn/webgpu.h
    static/include/dawn/webgpu_cpp.h
    static/include/dawn/native/DawnNative.h
    static/include/dawn/native/VulkanBackend.h
    static/include/vulkan/vulkan.h
    shared/lib/cmake/Dawn/DawnConfig.cmake
    shared/lib/cmake/Dawn/DawnTargets.cmake
    static/lib/cmake/Dawn/DawnConfig.cmake
    static/lib/cmake/Dawn/DawnTargets.cmake
    tools/bin/tint
    tools/bin/tint_info
    manifests/build-info.json
    manifests/elf-needed-libraries.txt
)
for relative_path in "${required_relative_paths[@]}"; do
    [[ -f $package_root/$relative_path ]] || fail "required package file is missing: $relative_path"
done
for variant in shared static; do
    [[ ! -e $package_root/$variant/include/dawn/wire ]] \
        || fail "unsupported Dawn wire headers leaked into $variant SDK"
done
[[ -x $package_root/tools/bin/tint ]] || fail "Tint CLI is not executable"
[[ -x $package_root/tools/bin/tint_info ]] || fail "Tint info CLI is not executable"

python3 - \
    "$package_root/manifests/build-info.json" \
    "$target_id" \
    "${DAWN_PACKAGE_SNAPSHOT:-unknown}" \
    "${DAWN_SECURITY_SNAPSHOT:-}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    build_info = json.load(stream)

if build_info.get("target") != sys.argv[2]:
    raise SystemExit("build-info target does not match requested target")
if build_info.get("architecture") != "x86_64":
    raise SystemExit("build-info architecture is not x86_64")
if build_info.get("variants") != {
    "shared": "shared/lib/libwebgpu_dawn.so",
    "static": "static/lib/libwebgpu_dawn.a",
}:
    raise SystemExit("build-info variant paths do not match package contract")
if build_info.get("tools") != ["tools/bin/tint", "tools/bin/tint_info"]:
    raise SystemExit("build-info Tint tools do not match package contract")
if build_info.get("package_repository_snapshot") != sys.argv[3]:
    raise SystemExit("build-info package snapshot does not match requested snapshot")
if build_info.get("security_repository_snapshot") != sys.argv[4]:
    raise SystemExit("build-info security snapshot does not match requested snapshot")
PY

for variant in shared static; do
    include_directory=$package_root/$variant/include
    for header in \
        webgpu/webgpu.h \
        dawn/webgpu.h; do
        printf '#include <%s>\n' "$header" \
            | clang -std=c11 -fsyntax-only -x c -I "$include_directory" - \
            || fail "$variant C header is not self-contained: $header"
    done
    for header in \
        webgpu/webgpu_cpp.h \
        webgpu/webgpu_cpp_print.h \
        dawn/webgpu_cpp.h \
        dawn/native/DawnNative.h \
        dawn/native/NullBackend.h \
        dawn/native/OpenGLBackend.h \
        dawn/native/VulkanBackend.h; do
        printf '#include <%s>\n' "$header" \
            | clang++ -std=c++20 -fsyntax-only -x c++ -I "$include_directory" - \
            || fail "$variant C++ header is not self-contained: $header"
    done
done

cat > "$work_directory/tint-smoke.wgsl" <<'EOF'
@compute @workgroup_size(1)
fn main() {}
EOF

for tint_format in wgsl spirv spvasm msl hlsl glsl; do
    tint_output=$work_directory/tint-smoke.$tint_format
    "$package_root/tools/bin/tint" \
        --format "$tint_format" \
        --output-name "$tint_output" \
        "$work_directory/tint-smoke.wgsl" \
        || fail "Tint failed to emit $tint_format"
    [[ -s $tint_output ]] || fail "Tint emitted empty $tint_format output"
done

"$package_root/tools/bin/tint_info" \
    --json "$work_directory/tint-smoke.wgsl" \
    > "$work_directory/tint-info.json" \
    || fail "tint_info failed to inspect WGSL"
python3 - "$work_directory/tint-info.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream)
PY

require_elf_x86_64() {
    local path=$1
    local label=$2
    local elf_headers

    elf_headers=$(readelf --file-header "$path" 2>&1) \
        || fail "not a readable ELF file: $label"
    printf '%s\n' "$elf_headers" | awk '
        /Class:/ { seen = 1; if ($2 != "ELF64") bad = 1 }
        END { exit !(seen && !bad) }
    ' || fail "ELF class is not consistently ELF64: $label"
    printf '%s\n' "$elf_headers" | awk '
        /Machine:/ {
            seen = 1
            if (index($0, "Advanced Micro Devices X86-64") == 0) bad = 1
        }
        END { exit !(seen && !bad) }
    ' || fail "ELF machine is not consistently x86_64: $label"
}

require_elf_x86_64 \
    "$package_root/shared/lib/libwebgpu_dawn.so" \
    shared/lib/libwebgpu_dawn.so
require_elf_x86_64 "$package_root/tools/bin/tint" tools/bin/tint
require_elf_x86_64 "$package_root/tools/bin/tint_info" tools/bin/tint_info

static_library=$package_root/static/lib/libwebgpu_dawn.a
ar t "$static_library" >/dev/null || fail "static Dawn library is not a readable archive"
static_headers=$(readelf --file-header "$static_library" 2>&1) \
    || fail "static Dawn archive does not contain readable ELF objects"
printf '%s\n' "$static_headers" | awk '
    /Class:/ { seen = 1; if ($2 != "ELF64") bad = 1 }
    END { exit !(seen && !bad) }
' || fail "static Dawn archive contains a non-ELF64 object"
printf '%s\n' "$static_headers" | awk '
    /Machine:/ {
        seen = 1
        if (index($0, "Advanced Micro Devices X86-64") == 0) bad = 1
    }
    END { exit !(seen && !bad) }
' || fail "static Dawn archive contains a non-x86_64 object"

cat > "$work_directory/smoke-source/smoke.c" <<'EOF'
#include <webgpu/webgpu.h>

struct AdapterRequest {
    WGPUAdapter adapter;
    WGPURequestAdapterStatus status;
    int completed;
};

static void on_adapter(WGPURequestAdapterStatus status,
                       WGPUAdapter adapter,
                       WGPUStringView message,
                       void* userdata1,
                       void* userdata2) {
    struct AdapterRequest* request = userdata1;
    (void)message;
    (void)userdata2;
    request->status = status;
    request->adapter = adapter;
    request->completed = 1;
}

static void on_error(WGPUDevice const* device,
                     WGPUErrorType type,
                     WGPUStringView message,
                     void* userdata1,
                     void* userdata2) {
    int* had_error = userdata1;
    (void)device;
    (void)type;
    (void)message;
    (void)userdata2;
    *had_error = 1;
}

int main(void) {
    int result = 0;
    int had_error = 0;
    WGPUAdapter adapter = NULL;
    WGPUDevice device = NULL;
    WGPUShaderModule shader = NULL;
    WGPUComputePipeline pipeline = NULL;
    WGPUQueue queue = NULL;
    WGPUCommandEncoder encoder = NULL;
    WGPUComputePassEncoder pass = NULL;
    WGPUCommandBuffer command = NULL;
    WGPUInstance instance = wgpuCreateInstance(NULL);
    if (instance == NULL) {
        return 1;
    }

    WGPURequestAdapterOptions options = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    options.backendType = WGPUBackendType_Null;
    struct AdapterRequest request = {0};
    WGPURequestAdapterCallbackInfo callback = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    callback.mode = WGPUCallbackMode_AllowProcessEvents;
    callback.callback = on_adapter;
    callback.userdata1 = &request;
    (void)wgpuInstanceRequestAdapter(instance, &options, callback);
    wgpuInstanceProcessEvents(instance);
    if (!request.completed || request.status != WGPURequestAdapterStatus_Success ||
        request.adapter == NULL) {
        result = 2;
        goto cleanup;
    }
    adapter = request.adapter;

    WGPUDeviceDescriptor device_descriptor = WGPU_DEVICE_DESCRIPTOR_INIT;
    device_descriptor.uncapturedErrorCallbackInfo.callback = on_error;
    device_descriptor.uncapturedErrorCallbackInfo.userdata1 = &had_error;
    device = wgpuAdapterCreateDevice(adapter, &device_descriptor);
    if (device == NULL) {
        result = 3;
        goto cleanup;
    }

    static const char shader_code[] = "@compute @workgroup_size(1) fn main() {}";
    WGPUShaderSourceWGSL wgsl = WGPU_SHADER_SOURCE_WGSL_INIT;
    wgsl.code.data = shader_code;
    wgsl.code.length = sizeof(shader_code) - 1;
    WGPUShaderModuleDescriptor shader_descriptor = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    shader_descriptor.nextInChain = &wgsl.chain;
    shader = wgpuDeviceCreateShaderModule(device, &shader_descriptor);
    if (shader == NULL) {
        result = 4;
        goto cleanup;
    }

    WGPUComputePipelineDescriptor pipeline_descriptor =
        WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    pipeline_descriptor.compute.module = shader;
    pipeline_descriptor.compute.entryPoint.data = "main";
    pipeline_descriptor.compute.entryPoint.length = 4;
    pipeline = wgpuDeviceCreateComputePipeline(device, &pipeline_descriptor);
    if (pipeline == NULL) {
        result = 5;
        goto cleanup;
    }

    queue = wgpuDeviceGetQueue(device);
    if (queue == NULL) {
        result = 6;
        goto cleanup;
    }

    encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
    if (encoder == NULL) {
        result = 7;
        goto cleanup;
    }
    pass = wgpuCommandEncoderBeginComputePass(encoder, NULL);
    if (pass == NULL) {
        result = 8;
        goto cleanup;
    }
    wgpuComputePassEncoderSetPipeline(pass, pipeline);
    wgpuComputePassEncoderDispatchWorkgroups(pass, 1, 1, 1);
    wgpuComputePassEncoderEnd(pass);
    command = wgpuCommandEncoderFinish(encoder, NULL);
    if (command == NULL) {
        result = 9;
        goto cleanup;
    }
    wgpuQueueSubmit(queue, 1, &command);
    wgpuDeviceTick(device);
    if (had_error) {
        result = 10;
    }

cleanup:
    if (command != NULL) wgpuCommandBufferRelease(command);
    if (pass != NULL) wgpuComputePassEncoderRelease(pass);
    if (encoder != NULL) wgpuCommandEncoderRelease(encoder);
    if (queue != NULL) wgpuQueueRelease(queue);
    if (pipeline != NULL) wgpuComputePipelineRelease(pipeline);
    if (shader != NULL) wgpuShaderModuleRelease(shader);
    if (device != NULL) wgpuDeviceRelease(device);
    if (adapter != NULL) wgpuAdapterRelease(adapter);
    wgpuInstanceRelease(instance);
    return result;
}
EOF

cat > "$work_directory/smoke-source/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.22)
project(dawn_c_abi_smoke LANGUAGES C CXX)

find_package(Dawn CONFIG REQUIRED)

add_executable(dawn_c_abi_smoke smoke.c)
set_target_properties(dawn_c_abi_smoke PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
    LINKER_LANGUAGE CXX
)
target_link_libraries(dawn_c_abi_smoke PRIVATE dawn::webgpu_dawn)
EOF

smoke_variant() {
    local variant=$1
    local build_directory=$work_directory/smoke-build-$variant
    local executable=$build_directory/dawn_c_abi_smoke
    local dynamic_entries

    cmake \
        -S "$work_directory/smoke-source" \
        -B "$build_directory" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DDawn_DIR="$package_root/$variant/lib/cmake/Dawn"
    cmake --build "$build_directory" --parallel 1
    require_elf_x86_64 "$executable" "$variant C ABI smoke executable"
    dynamic_entries=$(readelf --dynamic "$executable") \
        || fail "could not inspect $variant C ABI smoke executable linkage"

    if [[ $variant == shared ]]; then
        [[ $dynamic_entries == *libwebgpu_dawn.so* ]] \
            || fail "shared C ABI smoke executable did not link shared Dawn"
        LD_LIBRARY_PATH="$package_root/shared/lib" "$executable" \
            || fail "shared C ABI smoke executable failed"
    else
        if [[ $dynamic_entries == *libwebgpu_dawn.so* ]]; then
            fail "static C ABI smoke executable unexpectedly linked shared Dawn"
        fi
        env -u LD_LIBRARY_PATH "$executable" \
            || fail "static C ABI smoke executable failed"
    fi
}

smoke_variant shared
smoke_variant static

archive_sha256=$(sha256sum "$archive")
archive_sha256=${archive_sha256%% *}
cat > "$verification_directory/result.txt" <<EOF
status=passed
target=$target_id
archive=artifacts/$package_name.tar.zst
sha256=$archive_sha256
checks=zstd,tar-paths,contents-sha256,payload-contract,header-closure,elf-x86_64,tint-wgsl-spirv-spvasm-msl-hlsl-glsl,tint-info,cmake-c-abi-null-compute-dispatch-shared,cmake-c-abi-null-compute-dispatch-static
EOF

rm -rf -- "$work_directory"
trap - EXIT
echo "verified $archive"
