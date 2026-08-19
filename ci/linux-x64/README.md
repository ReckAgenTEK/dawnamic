# Dawn Linux x64 redistributable SDK builds

This pipeline builds the Dawn revision pinned by the parent repository. It produces one redistributable archive per target and does not update the fork, run Dawn's upstream test suite, publish container images, or execute host GPU workloads.

## Targets and scheduling

`targets.json` is the source of truth for target IDs, display names, runner labels, Dockerfiles, base images, build types, and artifact retention. Current targets are:

| Target | Build contract | Container image |
| --- | --- | --- |
| `archlinux-x64` | Arch Linux | digest-pinned `archlinux:base-devel` |
| `steamos-x64` | Steam Linux Runtime 4 for SteamOS | pinned Valve SteamRT4 SDK |
| `ubuntu-26.04-x64` | Ubuntu 26.04 | digest-pinned `ubuntu:26.04` |
| `debian-13-x64` | Debian 13 | digest-pinned `debian:13` |

The dedicated `archlinux-x64.yml` caller invokes `_linux-x64-sdk.yml` with only `archlinux-x64` on trusted pushes to `main` and manual dispatch. The general `linux-x64.yml` caller is manual-only and can resolve `all` or any selected catalog list. The reusable workflow creates one independent matrix job per target. All jobs use `[self-hosted, X64, Linux, arch-build]` by default.

Each job verifies GitHub runner name `arch-build-01`, service user `builder`, Linux/X64 identity, Docker client access, and Linux x86_64 Docker daemon before building. This fails closed if matching labels are accidentally assigned to a different host.

One runner service executes one job at a time, so all target jobs queue on `arch-build-01`. Additional runner services with the same labels let independent distro jobs run concurrently. Another workflow can reuse the same machinery:

```yaml
jobs:
  selected-linux-builds:
    uses: ./.github/workflows/_linux-x64-sdk.yml
    with:
      targets: '["steamos-x64", "debian-13-x64"]'
```

## Artifact contract

Every target archive contains:

```text
dawn-<target>/
├── shared/                 # libwebgpu_dawn.so, headers, CMake metadata
├── static/                 # libwebgpu_dawn.a, headers, CMake metadata
├── tools/bin/              # tint and tint_info
├── licenses/               # Dawn and fetched dependency notices
└── manifests/              # source, toolchain, ABI dependency, and checksums
```

Shared and static builds use separate CMake and install trees because both variants export the same `dawn::webgpu_dawn` CMake target. Consumers select either `shared/` or `static/` as their CMake prefix; merging their CMake metadata would make linkage ambiguous.

Both variants expose Dawn's WebGPU C ABI and public C/C++ headers. The pinned Vulkan-Headers tree is bundled because Dawn's public `VulkanBackend.h` depends on it. Enabled native backends are Vulkan, desktop OpenGL, OpenGL ES, and Null. X11 surface support is enabled. Wayland presentation is supported through Vulkan; the pinned Dawn revision does not support Wayland presentation through its EGL OpenGL path.

Tint's `tint` and `tint_info` CLIs are built with WGSL, SPIR-V, GLSL, HLSL, and MSL translation support. Dawn embeds the Tint code needed by its shader pipeline. Tint's internal C++ libraries are not presented as a standalone SDK because this Dawn revision has no stable, self-contained Tint install package.

Tests, benchmarks, fuzzers, samples, Node bindings, `tintd`, protobuf IR fuzz tools, and SwiftShader are intentionally excluded because they are not redistributable Dawn SDK payloads.

## SteamOS compatibility

`steamos-x64` is still a Docker build. It uses Valve's pinned Steam Linux Runtime 4 SDK image, the supported build contract for new native Steam Linux applications. Its output targets the SteamRT4 runtime available on SteamOS; it is not a package linked against the rolling Arch host libraries used by SteamOS itself.

GPU drivers and distribution system libraries are not copied into the archive. Runtime-loaded and ELF-linked dependencies are recorded under `manifests/` so downstream `.pkg.tar.zst`, `.deb`, or application packages can declare or bundle the correct target dependencies.

Base OCI images and distro package-repository snapshots are pinned. Every archive records those inputs and exact installed container package versions. Update image digests and snapshot IDs deliberately in `targets.json` and Dockerfile defaults when advancing a build environment.

## Local deterministic harness

Run all configured targets on the Docker host:

```bash
ci/linux-x64/local-build.sh --repack-check all
```

Target IDs, comma-separated lists, and JSON arrays are accepted. `--repack-check` packages the same completed build twice into separate files and requires identical SHA-256 hashes; it never replaces the verified canonical archive.

Persistent local outputs:

- `out/<target>/artifacts/`: archive plus adjacent `.sha256` file.
- `out/<target>/verification/result.txt`: exact checks and verified archive hash.
- `out/workflow-logs/<target>.log`: GitHub Actions execution log retained even after a failed build.
- `out/local-build/logs/<target>.log`: full build and verification log.
- `out/local-build/artifacts.sha256`: aggregate hashes for all current target archives.
- `out/local-build/resolved-targets.json`: matrix from the most recent harness invocation.

Verification checks archive integrity and paths, complete content checksums, header closure, x86_64 ELF/archive identity, Tint translation formats, CMake consumption, and C ABI runtime creation of a Null adapter, device, WGSL compute pipeline, command encoder, dispatch, and queue submission through both shared and static Dawn. Vulkan/OpenGL/OpenGL ES driver execution remains a downstream integration test because GPU drivers are intentionally not bundled.

GitHub Actions publishes uniquely named archive, SHA-256, verification-receipt, and execution-log artifacts. Successful verification is copied into the job summary; failures produce an explicit summary and retain the execution log when one exists.

## Adding a distribution or pipeline

1. Add a Dockerfile under `ci/linux-x64/docker/` that installs the common build and platform headers.
2. Add one object to `targets.json` with target ID, image, Dockerfile, and any default overrides.
3. Invoke `_linux-x64-sdk.yml` with `all` or the target IDs wanted by that pipeline.

No Dawn CMake logic is duplicated per distro. Dockerfiles own distro packages; `build-dawn.sh` owns the shared build contract; `package-dawn.sh` owns the archive contract.

Windows should use a separate native workflow for `win-build-o1` with `[self-hosted, Windows, X64, win-build]`; it does not belong in this Linux container matrix.

## Trust boundary

The workflow runs on trusted pushes to `main` and manual dispatch. It does not run pull requests because Docker access on a persistent self-hosted runner is host-privileged.
