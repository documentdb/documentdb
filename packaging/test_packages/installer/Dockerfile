# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

RUN if command -v apt-get >/dev/null 2>&1; then \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            systemd systemd-sysv dbus ca-certificates curl gnupg \
            python3 openssl iproute2 procps locales && \
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
        locale-gen && \
        rm -rf /var/lib/apt/lists/*; \
    else \
        dnf install -y \
            systemd dbus ca-certificates curl-minimal gnupg2 \
            python3 openssl iproute procps-ng \
            glibc-langpack-en glibc-common && \
        dnf clean all; \
    fi

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

COPY repository/ /srv/documentdb-installer-repository/
COPY repository-server.crt /etc/documentdb-installer-e2e/repository-server.crt
COPY repository-server.key /etc/documentdb-installer-e2e/repository-server.key
COPY repository-server.crt /usr/local/share/ca-certificates/documentdb-installer-e2e.crt
COPY serve-test-repository.py /usr/local/bin/serve-test-repository.py
COPY installer-test-repository.service /etc/systemd/system/installer-test-repository.service
COPY install.sh /opt/documentdb-installer/install.sh
COPY run-inside-container.sh /usr/local/bin/run-installer-e2e.sh

RUN chmod 0600 /etc/documentdb-installer-e2e/repository-server.key && \
    chmod 0755 /usr/local/bin/serve-test-repository.py \
        /usr/local/bin/run-installer-e2e.sh /opt/documentdb-installer/install.sh && \
    install -m 0600 /dev/null /etc/documentdb-installer-test-repository && \
    if command -v update-ca-certificates >/dev/null 2>&1; then \
        update-ca-certificates; \
    else \
        cp /usr/local/share/ca-certificates/documentdb-installer-e2e.crt \
            /etc/pki/ca-trust/source/anchors/documentdb-installer-e2e.crt && \
        update-ca-trust; \
    fi && \
    systemctl enable installer-test-repository.service && \
    (systemctl mask \
        systemd-udevd.service systemd-udev-trigger.service \
        systemd-modules-load.service sys-kernel-config.mount \
        sys-kernel-debug.mount sys-kernel-tracing.mount \
        systemd-journald-audit.socket || true)

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
