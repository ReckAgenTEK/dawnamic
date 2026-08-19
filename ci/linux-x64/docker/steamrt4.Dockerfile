ARG BASE_IMAGE=registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk:4.0.20260805.254769@sha256:2ff6220464894964266c7dbda1b91ca24e433a58ad3edff26571a2a9e5163e00
FROM ${BASE_IMAGE}
ARG PACKAGE_SNAPSHOT=20260817T203319Z
ARG SECURITY_SNAPSHOT=20260817T234556Z

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
    && printf '%s\n' \
        "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/${PACKAGE_SNAPSHOT}/ trixie main" \
        "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/${PACKAGE_SNAPSHOT}/ trixie-updates main" \
        "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian-security/${SECURITY_SNAPSHOT}/ trixie-security main" \
        > /etc/apt/sources.list.d/snapshot.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        file \
        patchelf \
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
