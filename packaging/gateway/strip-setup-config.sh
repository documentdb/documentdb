#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (c) Microsoft Corporation.
#
# Shared build-time helper: strip connection-pinning and credential fields
# from SetupConfiguration.json so packaged installs are env-driven. The live
# values come from gateway.env (EnvironmentFile) at runtime, never from the
# shipped JSON, so leaving the dev-tree PostgresPort / GatewayListenPort /
# PostgresDataUserPassword / host / user fields in the package would
# contradict the per-major port promise and the passwordless local-peer
# policy.
#
# This is the single source of truth for the strip logic: it is invoked from
# BOTH the DEB build (oss/packaging/gateway/build-gateway-deb.sh) and the RPM
# spec %install (oss/packaging/rpm/spec/documentdb-gateway.spec, which stages
# this file into SOURCES via the rhel-8/rhel-9 Dockerfiles). Keeping it in one
# place means the stripped-field set cannot drift between packaging families.
#
# Both backends parse and re-serialize the JSON so the result is ALWAYS valid:
# a line-level deletion (e.g. sed) would leave a dangling comma - and therefore
# invalid JSON - whenever a stripped field happened to be the last property in
# the object.
#
# Usage: strip-setup-config.sh <src.json> <dst.json>

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <src.json> <dst.json>" >&2
    exit 2
fi

SRC="$1"
DST="$2"

if command -v jq >/dev/null 2>&1; then
    jq 'del(.PostgresPort, .GatewayListenPort, .PostgresDataUserPassword, .PostgresHostName, .PostgresSystemUser, .PostgresDataUser)' \
        "${SRC}" > "${DST}"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "${SRC}" "${DST}" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
strip = {
    "PostgresPort",
    "GatewayListenPort",
    "PostgresDataUserPassword",
    "PostgresHostName",
    "PostgresSystemUser",
    "PostgresDataUser",
}
with open(src, encoding="utf-8") as fh:
    data = json.load(fh)
for key in strip:
    data.pop(key, None)
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
else
    echo "ERROR: jq or python3 is required to strip connection-pinning fields from SetupConfiguration.json" >&2
    exit 1
fi
