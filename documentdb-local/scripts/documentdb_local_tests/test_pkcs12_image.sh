#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Run with bash test_pkcs12_image.sh <built documentdb-local image>.
set -euo pipefail

# All key material lives in tmpfs. No host ports, credentials or volumes needed.
docker run --rm -i --network none --tmpfs /tmp:mode=1777 \
    -e DOCUMENTDB_USAGE_TELEMETRY=false --entrypoint bash "${1:?image required}" -s <<'TEST'
set -euo pipefail
umask 077
cd /tmp
openssl rand -hex 32 > bundle-password
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=root \
    -addext basicConstraints=critical,CA:TRUE -out root.crt -keyout root.key 2>/dev/null
for name in intermediate server; do
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$name" \
        -out "$name.csr" -keyout "$name.key" 2>/dev/null
done
openssl x509 -req -in intermediate.csr -CA root.crt -CAkey root.key -CAcreateserial -days 1 \
    -extfile <(printf '%s\n' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign') -out intermediate.crt
openssl x509 -req -in server.csr -CA intermediate.crt -CAkey intermediate.key -CAcreateserial -days 1 \
    -extfile <(printf '%s\n' 'subjectAltName=DNS:localhost' 'basicConstraints=CA:FALSE') -out server.crt
openssl pkcs12 -export -in server.crt -inkey server.key -certfile intermediate.crt \
    -out server.PfX -passout file:bundle-password
rm root.key intermediate.key server.key
PASSWORD=$(openssl rand -hex 24)
export PASSWORD
openssl rand -hex 32 > wrong-password
rc=0
timeout 20 /home/documentdb/gateway/scripts/emulator_entrypoint.sh --cert-path /tmp/server.PfX \
    --cert-password-file /tmp/wrong-password --start-pg false --create-user false \
    </dev/null >rejected.log 2>&1 || rc=$?
test "$rc" = 1
grep -Fq 'could not load the PKCS#12' rejected.log
if compgen -G '/tmp/documentdb-tls.*' >/dev/null; then echo 'Failed extraction was not cleaned up' >&2; exit 1; fi
printf '%s\n' 'ignored second line' >> bundle-password
/home/documentdb/gateway/scripts/emulator_entrypoint.sh --cert-path /tmp/server.PfX \
    --cert-password-file /tmp/bundle-password --tlsMode requireTLS --init-data false </dev/null >boot.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" || true' EXIT
deadline=$((SECONDS + 120))
until openssl s_client -connect localhost:10260 -verify_hostname localhost -verify_return_error \
    -CAfile root.crt -brief </dev/null >/dev/null 2>&1; do
    kill -0 "$pid" && (( SECONDS < deadline )) || { echo 'Verified TLS handshake failed' >&2; exit 1; }
    sleep 1
done
test "$(stat -c %a /tmp/documentdb-tls.*)" = 700
for pem in /tmp/documentdb-tls.*/*.pem; do test "$(stat -c %a "$pem")" = 600; done
mongosh --host localhost --port 10260 --username default_user --password "$PASSWORD" \
    --authenticationDatabase admin --tls --tlsCAFile root.crt --quiet \
    --eval 'quit(db.runCommand({ping: 1}).ok === 1 ? 0 : 1)'
kill -TERM "$pid"
wait "$pid"
trap - EXIT
if compgen -G '/tmp/documentdb-tls.*' >/dev/null; then echo 'Extracted identity survived shutdown' >&2; exit 1; fi
echo 'PKCS#12: verified intermediate chain, authenticated ping, private PEM permissions and shutdown cleanup'
TEST