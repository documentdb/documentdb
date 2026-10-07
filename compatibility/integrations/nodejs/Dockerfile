# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

FROM node:24.21.0-bookworm-slim@sha256:5cbc7caba8c2c0f0bca675d1b61b9f2857e1cf1853c6164ee9dd409501a936e7

WORKDIR /app
COPY npm-packages /npm-packages
COPY package.json package-lock.json ./
RUN for package in /npm-packages/*.tgz; do npm cache add --offline --ignore-scripts "$package"; done \
    && npm ci --offline --ignore-scripts --engine-strict --omit=optional --no-audit --no-fund \
    && npm cache clean --force
COPY install-report.json /install-report.json
COPY compatibility /app/compatibility
USER node
ENV COMPATIBILITY_ACTIVE=1
ENTRYPOINT ["node", "compatibility/client.cjs"]
