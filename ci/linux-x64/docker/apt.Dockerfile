ARG BASE_IMAGE=debian:13@sha256:d8f17b92dc7ff10f9c1fdecab0ad21103d1d24aed823c3a0359e4f50adfab3eb
FROM ${BASE_IMAGE}
ARG PACKAGE_SNAPSHOT=20260817T203319Z
ARG SECURITY_SNAPSHOT=20260817T234556Z

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN . /etc/os-release \
    && case "$ID" in \
        ubuntu) \
            mv /etc/apt/sources.list.d/ubuntu.sources /tmp/ubuntu.sources; \
            printf '%s\n' \
                'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu resolute main' \
                > /etc/apt/sources.list.d/ca-bootstrap.list; \
            apt-get update; \
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                ca-certificates=20260223 \
                openssl=3.5.5-1ubuntu3; \
            rm -f /etc/apt/sources.list.d/ca-bootstrap.list; \
            rm -rf /var/lib/apt/lists/*; \
            mv /tmp/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources; \
            sed -i "/^Signed-By:/a Snapshot: ${PACKAGE_SNAPSHOT}" \
                /etc/apt/sources.list.d/ubuntu.sources; \
            ;; \
        debian) \
            rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*; \
            printf '%s\n' \
                'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie main' \
                > /etc/apt/sources.list.d/ca-bootstrap.list; \
            apt-get update; \
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                ca-certificates=20250419 \
                openssl=3.5.6-1~deb13u2; \
            rm -f /etc/apt/sources.list.d/ca-bootstrap.list; \
            rm -rf /var/lib/apt/lists/*; \
            printf '%s\n' \
                "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/${PACKAGE_SNAPSHOT}/ trixie main" \
                "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/${PACKAGE_SNAPSHOT}/ trixie-updates main" \
                "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian-security/${SECURITY_SNAPSHOT}/ trixie-security main" \
                > /etc/apt/sources.list.d/snapshot.list; \
            ;; \
        *) \
            echo "unsupported apt image: $ID" >&2; \
            exit 2; \
            ;; \
        esac \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        file \
        git \
        libegl-dev \
        libgl-dev \
        libgles-dev \
        libopengl-dev \
        libvulkan-dev \
        libwayland-dev \
        libxcb1-dev \
        libx11-dev \
        libx11-xcb-dev \
        libxcursor-dev \
        libxext-dev \
        libxfixes-dev \
        libxi-dev \
        libxinerama-dev \
        libxkbcommon-dev \
        libxrandr-dev \
        ninja-build \
        patchelf \
        pkgconf \
        python3 \
        python-is-python3 \
        wayland-protocols \
        zstd \
    && rm -rf /var/lib/apt/lists/*

COPY build-dawn.sh package-dawn.sh verify-package.sh /usr/local/bin/
RUN chmod 0755 \
        /usr/local/bin/build-dawn.sh \
        /usr/local/bin/package-dawn.sh \
        /usr/local/bin/verify-package.sh

ENV CC=clang \
    CXX=clang++ \
    LANG=C.UTF-8

ENTRYPOINT ["/usr/local/bin/build-dawn.sh"]
