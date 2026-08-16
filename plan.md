# Google Dawn Build and Integration Plan

## 1. Objective

Build the pinned Google Dawn source in this repository, verify its native WebGPU implementation on the current Arch Linux host, and establish a clean path for the parent project to consume Dawn.

The first milestone should prove the toolchain and Dawn itself before application-specific code is added. This keeps build failures separate from integration failures.

## 2. Current Repository State

- The parent repository is on `main` and clean.
- Dawn is included at `modules/dawn` as a Git submodule.
- The parent repository pins Dawn to commit `56f332d7d8d03f36149f201ab8cce8aee187e8c6`.
- The submodule is on `main` and tracks `origin/main` from `git@github.com-mannsion:ReckAgenTEK/dawn.git`.
- Dawn's nested dependency repositories are not initialized yet.
- The parent project has no build system or application source yet.
- Generated `build/`, `out/`, and related directories are already ignored.

The `branch = main` entry in `.gitmodules` does not make Dawn float automatically. The parent repository always records an exact Dawn commit. Updating Dawn requires an explicit submodule update followed by a parent commit containing the new gitlink.

## 3. Dawn Components in Scope

### Required for the initial native library

- WebGPU C headers (`webgpu.h`)
- WebGPU C++ wrapper
- Dawn native WebGPU implementation
- Tint WGSL compiler
- Dawn procedure dispatch
- Platform and utility libraries
- Vulkan backend
- Null backend for hardware-independent smoke checks
- Installable monolithic `dawn::webgpu_dawn` CMake target

### Deferred until required

- Dawn wire client/server integration
- OpenGL and OpenGL ES backends
- GLFW samples and window surfaces
- Node.js bindings
- Benchmarks and fuzzers
- SwiftShader
- Full WebGPU Conformance Test Suite
- Cross-compilation for Windows, macOS, Android, or WebAssembly

## 4. Decisions Required Before Application Integration

The standalone Dawn build can proceed with proposed defaults. Application integration should wait until these choices are confirmed.

| Decision | Proposed default | Why it matters |
| --- | --- | --- |
| Consumption model | Build and install Dawn first; use `find_package(Dawn)` from parent | Separates Dawn build failures from parent integration failures |
| Public API | Dawn's C++ WebGPU wrapper | Best fit for a native C++ smoke executable; other languages may prefer the C API |
| Native backend | Vulkan plus Null | Vulkan is the primary Linux GPU path; Null supports hardware-independent checks |
| Window system | Headless for first milestone | Avoids mixing Wayland/X11 surface work into initial library proof |
| Linkage | Static monolithic library | Simplest deployment and matches Dawn's CMake default |
| Build types | Release library plus separate Debug verification build | Covers production output and useful diagnostics |
| Node bindings | Disabled | Avoids unnecessary Go, Node API, and npm dependencies |
| Primary GPU | AMD iGPU for display/surface smoke; RX 6950 XT for discrete-GPU tests | Matches current display ownership and high-performance render layout |
| RTX 4090 | Optional test target | Availability can change when GPU is bound to `vfio-pci` |

If the parent application will be written in Zig, Rust, C#, or another language, decide whether it will bind the stable C `webgpu.h` API directly or use a dedicated wrapper before creating parent build files.

## 5. Toolchain and Dependency State

### Installed and ready

- CMake 4.3.3
- Ninja 1.13.2
- Python 3.14.5
- Clang 22.1.6
- GCC 16.1.1
- `pkg-config`
- `fuse2`
- X11, Xrandr, Xinerama, and Xcursor development files
- Wayland libraries
- Mesa
- Vulkan loader and RADV driver

The pinned Dawn `CMakeLists.txt` requires CMake 3.22 or newer, despite older wording in part of Dawn's documentation. The installed version satisfies the actual source requirement.

Clang 22 is the preferred compiler for this host. It avoids Dawn's documented compatibility problem involving older Clang releases and newer GCC standard-library headers.

### Missing or optional

- Go is not installed. Dawn documents Go 1.23 or newer; the current CMake build uses it directly only when Node bindings are enabled. Arch provides `go` 1.26.5.
- `depot_tools`, `gclient`, `gn`, and `autoninja` are not installed. They are not required for the embedder-oriented CMake path.
- `wayland-protocols` is not installed. It may be needed when Wayland/GLFW samples are enabled.
- Vulkan headers are not installed system-wide. Dawn's dependency fetch supplies its pinned Vulkan headers.
- Vulkan validation layers are not installed. They are optional but useful for validation-heavy GPU testing.
- `ccache` and `sccache` are not installed. They are optional build accelerators.

No package installation should occur until the selected build profile proves it needs the package. Any Arch package transaction should be reviewed separately before execution.

## 6. Dependency Bootstrap Strategy

Use Dawn's documented CMake dependency path:

```text
DAWN_FETCH_DEPENDENCIES=ON
```

During the first CMake configure, Dawn runs `tools/fetch_dawn_dependencies.py` against its pinned `DEPS` file. This populates the required dependency checkouts under `modules/dawn` without requiring `depot_tools`.

Important behavior:

- The first configure requires network access and may take substantial time and disk space.
- The fetch script executes the trusted pinned `DEPS` file.
- Dependency versions remain tied to the pinned Dawn commit.
- Dawn's own submodule should remain clean after dependencies are fetched at the expected revisions.
- Do not mix the CMake dependency fetch and a separate `gclient sync` workflow in the same checkout.

Use `depot_tools` and GN only if the project begins modifying Dawn itself or needs Chromium-equivalent build behavior.

## 7. Phase 1: Build an Installable Release Library

Configure a minimal, headless Vulkan build with Clang and Ninja:

```bash
cmake -S modules/dawn -B out/dawn-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DDAWN_FETCH_DEPENDENCIES=ON \
  -DDAWN_ENABLE_INSTALL=ON \
  -DDAWN_BUILD_MONOLITHIC_LIBRARY=STATIC \
  -DDAWN_ENABLE_VULKAN=ON \
  -DDAWN_ENABLE_NULL=ON \
  -DDAWN_ENABLE_DESKTOP_GL=OFF \
  -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_USE_X11=OFF \
  -DDAWN_USE_WAYLAND=OFF \
  -DDAWN_USE_GLFW=OFF \
  -DDAWN_BUILD_SAMPLES=OFF \
  -DDAWN_BUILD_TESTS=OFF \
  -DTINT_BUILD_TESTS=OFF \
  -DDAWN_BUILD_NODE_BINDINGS=OFF \
  -DDAWN_BUILD_BENCHMARKS=OFF \
  -DDAWN_BUILD_FUZZERS=OFF
```

Build the monolithic library:

```bash
cmake --build out/dawn-release --parallel 32 --target webgpu_dawn
```

Install it into a repository-local, ignored directory:

```bash
cmake --install out/dawn-release --prefix out/dawn-install
```

Expected result:

- Static Dawn library
- Public WebGPU C and C++ headers
- Dawn CMake package configuration
- Importable `dawn::webgpu_dawn` target

## 8. Phase 2: Add a Parent Integration Smoke Test

After the parent language and API choice are confirmed, add the smallest possible consumer:

1. Create the parent build definition.
2. Point `CMAKE_PREFIX_PATH` at `out/dawn-install`.
3. Discover Dawn with `find_package(Dawn REQUIRED)`.
4. Link one small executable against `dawn::webgpu_dawn`.
5. Create a WebGPU instance.
6. Request an adapter.
7. Print vendor, device, architecture, and driver information.
8. Request a device and exit cleanly.

For a CMake-based C++ consumer, the key integration is:

```cmake
find_package(Dawn REQUIRED)
target_link_libraries(dawn_smoke PRIVATE dawn::webgpu_dawn)
```

The smoke test should initially avoid window creation, swapchains, shaders, and rendering. Those belong after adapter and device creation are proven.

## 9. Phase 3: Build a Debug Verification Profile

Create a separate build directory. Never reuse the Release cache for Debug or test options.

Use the same compiler and backend choices, with these changes:

```text
CMAKE_BUILD_TYPE=Debug
DAWN_BUILD_TESTS=ON
TINT_BUILD_TESTS=ON
DAWN_ALWAYS_ASSERT=ON
DAWN_ENABLE_INSTALL=OFF
```

Build the focused verification targets:

```bash
cmake --build out/dawn-debug --parallel 32 --target \
  webgpu_dawn \
  dawn_end2end_tests \
  tint_cmd_test_test_cmd
```

Run Tint's registered CTest entry:

```bash
ctest --test-dir out/dawn-debug -R tint_unittests --output-on-failure
```

Run Dawn's end-to-end executable directly because its CMake build does not register it with CTest at the pinned revision.

Hardware-independent pass:

```bash
out/dawn-debug/dawn_end2end_tests --backend=null
```

RX 6950 XT Vulkan pass:

```bash
out/dawn-debug/dawn_end2end_tests \
  --backend=vulkan \
  --adapter-vendor-id=1002 \
  --exclusive-device-type-preference=discrete
```

AMD integrated Vulkan pass:

```bash
out/dawn-debug/dawn_end2end_tests \
  --backend=vulkan \
  --adapter-vendor-id=1002 \
  --exclusive-device-type-preference=integrated
```

Run the wire path separately if the parent project will use Dawn wire:

```bash
out/dawn-debug/dawn_end2end_tests --backend=vulkan --use-wire
```

Use GoogleTest filters for the first run rather than treating the entire end-to-end suite as the initial gate. Expand coverage after the smoke set is stable.

## 10. Phase 4: Add Rendering and Window Surfaces

Only begin this phase if the application needs visible rendering.

1. Choose Wayland-only, X11-only, or dual surface support.
2. Install only the missing system development packages required by that choice.
3. Enable the matching Dawn options.
4. Decide whether Dawn's GLFW utility should be used or whether the parent project owns window creation.
5. Add a triangle or clear-color render smoke test.
6. Test presentation first on the AMD iGPU because it owns the current display path.
7. Test the RX 6950 XT separately as the high-performance render adapter.
8. Treat RTX 4090 results as conditional on its current host/VFIO binding.

Relevant CMake options:

```text
DAWN_USE_WAYLAND
DAWN_USE_X11
DAWN_USE_GLFW
DAWN_BUILD_SAMPLES
DAWN_ENABLE_DESKTOP_GL
DAWN_ENABLE_OPENGLES
```

Vulkan should remain the primary backend unless the project has a concrete OpenGL compatibility requirement.

## 11. Test and Validation Gates

### Required before integration work

- Dawn dependencies fetch successfully at pinned revisions.
- CMake configure completes without silently changing intended backend options.
- `webgpu_dawn` builds with Clang 22.
- The install step produces a usable Dawn CMake package.

### Required before calling native integration complete

- Parent smoke executable links only through installed/public Dawn interfaces.
- WebGPU instance creation succeeds.
- Adapter enumeration succeeds.
- Device creation succeeds.
- Adapter identity matches the explicitly selected GPU.
- Null backend smoke passes.
- Focused Vulkan end-to-end tests pass on at least one AMD GPU.
- Tint unit tests pass.
- Parent repository and Dawn submodule remain clean except for intentional parent changes.

### Optional later gates

- Full Dawn end-to-end suite
- Dawn wire pass
- Vulkan validation-layer pass
- Wayland and/or X11 presentation test
- RX 6950 XT and RTX 4090 matrix
- Sanitizer builds
- WebGPU CTS
- Benchmarks

## 12. Multi-GPU Test Policy

The host currently exposes three Vulkan devices:

- AMD Ryzen integrated GPU using RADV
- AMD Radeon RX 6950 XT using RADV
- NVIDIA GeForce RTX 4090 using the proprietary driver

Tests must select adapters explicitly. Otherwise, results can vary with driver ordering, session state, or VFIO binding.

Recommended policy:

- Use the AMD iGPU for display-owned presentation checks.
- Use the RX 6950 XT for discrete-GPU correctness and performance checks.
- Use the Null backend for hardware-independent checks.
- Run RTX 4090 checks only when it is intentionally attached to the host.

GPU tests need host device access. They should not be interpreted from a restricted filesystem/network sandbox where Vulkan device enumeration can fail even though the host is healthy.

## 13. Dawn Update Procedure

When intentionally updating the fork's `main` branch:

1. Confirm the parent worktree is clean.
2. Fetch and update `modules/dawn` to the desired `origin/main` revision.
3. Record the old and new Dawn commit hashes.
4. Refresh Dawn dependencies using the same dependency strategy.
5. Reconfigure from fresh Release and Debug build directories if Dawn build options changed materially.
6. Run the required build and validation gates.
7. Commit the parent repository's updated submodule gitlink.

Never treat `branch = main` as permission for unattended dependency updates. Every Dawn revision change should remain reviewable and reproducible.

## 14. Risks and Controls

| Risk | Control |
| --- | --- |
| Large initial dependency fetch and build | Keep all output under ignored `out/`; use focused targets first |
| Build-option drift from Dawn defaults | Set important backend, test, sample, and linkage options explicitly |
| Multi-GPU nondeterminism | Select backend, vendor, and device type in tests |
| RTX 4090 changes between host and VFIO use | Keep NVIDIA testing optional and state-dependent |
| Mixing dependency managers | Use CMake fetch for embedding; use GN/gclient only after an explicit workflow change |
| Dirty vendored source | Verify both parent and Dawn submodule status after dependency fetch and tests |
| Long rebuild times | Add `ccache` only after first successful build proves need |
| Premature application architecture | Complete standalone library and adapter smoke milestones before rendering features |

## 15. Completion Criteria

This plan is complete when:

1. Proposed defaults and unresolved integration decisions are confirmed.
2. Release `webgpu_dawn` builds and installs successfully.
3. A parent smoke executable consumes the installed package.
4. Instance, adapter, and device creation succeed on the selected GPU.
5. Focused Null, Vulkan, and Tint verification passes.
6. Build commands and selected options are documented in the parent repository.
7. No generated output or dependency noise is committed.
8. Dawn remains pinned to an explicit, tested commit.
