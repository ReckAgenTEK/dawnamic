ARG BASE_IMAGE=archlinux:base-devel@sha256:aecf5b39bd3139a951090dfb3d940f9317e4c5fca038c65fb49ac03910f7133e
FROM ${BASE_IMAGE}
ARG PACKAGE_SNAPSHOT=2026/08/18
ARG SECURITY_SNAPSHOT=

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' \
        "$PACKAGE_SNAPSHOT" > /etc/pacman.d/mirrorlist \
    && pacman -Syyuu --noconfirm --needed \
        clang \
        cmake \
        file \
        git \
        libglvnd \
        libxcb \
        libx11 \
        libxext \
        libxrandr \
        libxinerama \
        libxcursor \
        libxfixes \
        libxi \
        libxkbcommon \
        mesa \
        ninja \
        patchelf \
        pkgconf \
        python \
        vulkan-headers \
        vulkan-icd-loader \
        wayland \
        wayland-protocols \
        xorgproto \
        zstd \
    && pacman -Scc --noconfirm

COPY build-dawn.sh package-dawn.sh verify-package.sh /usr/local/bin/
RUN chmod 0755 \
        /usr/local/bin/build-dawn.sh \
        /usr/local/bin/package-dawn.sh \
        /usr/local/bin/verify-package.sh

ENV CC=clang \
    CXX=clang++ \
    LANG=C.UTF-8

ENTRYPOINT ["/usr/local/bin/build-dawn.sh"]
