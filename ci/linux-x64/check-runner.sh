#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 2 )); then
    echo "usage: $0 <runner-name> <runner-user>" >&2
    exit 2
fi

expected_name=$1
expected_user=$2
actual_user=$(id -un)

if [[ ${GITHUB_ACTIONS:-} != true ]]; then
    echo "runner preflight must execute inside GitHub Actions" >&2
    exit 2
fi
if [[ ${RUNNER_NAME:-} != "$expected_name" ]]; then
    echo "unexpected GitHub runner: ${RUNNER_NAME:-unset}; expected $expected_name" >&2
    exit 2
fi
if [[ ${RUNNER_OS:-} != Linux || ${RUNNER_ARCH:-} != X64 ]]; then
    echo "unexpected runner platform: ${RUNNER_OS:-unset}/${RUNNER_ARCH:-unset}; expected Linux/X64" >&2
    exit 2
fi
if [[ $actual_user != "$expected_user" ]]; then
    echo "unexpected runner service user: $actual_user; expected $expected_user" >&2
    exit 2
fi
case $(uname -m) in
    x86_64 | amd64) ;;
    *)
        echo "runner host is not x86_64: $(uname -m)" >&2
        exit 2
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is unavailable on runner $expected_name" >&2
    exit 2
fi
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is unavailable to user $actual_user" >&2
    exit 2
fi

docker_os=$(docker info --format '{{.OSType}}')
docker_arch=$(docker info --format '{{.Architecture}}')
case $docker_arch in
    x86_64 | amd64) ;;
    *)
        echo "Docker daemon is not x86_64: $docker_arch" >&2
        exit 2
        ;;
esac
if [[ $docker_os != linux ]]; then
    echo "Docker daemon is not Linux: $docker_os" >&2
    exit 2
fi

docker_version=$(docker version --format '{{.Server.Version}}')
printf 'runner=%s user=%s platform=%s/%s docker=%s\n' \
    "$RUNNER_NAME" "$actual_user" "$RUNNER_OS" "$RUNNER_ARCH" "$docker_version"
