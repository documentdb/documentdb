# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/gateway.sh: the gateway configuration file and the host config.
#
# Sourced by emulator_entrypoint.sh; defines functions only.

is_pkcs12_bundle() {
    [[ ${CERT_PATH:-} == *.[pP][fF][xX] || ${CERT_PATH:-} == *.[pP]12 ]]
}

extract_pkcs12_bundle() (
    umask 077
    local passin=pass: cert_public key_public
    [[ -f $CERT_PATH && -r $CERT_PATH ]] || return 1
    if [[ -n ${CERT_PASSWORD_FILE:-} ]]; then
        [[ -f $CERT_PASSWORD_FILE && -r $CERT_PASSWORD_FILE ]] || return 1
        passin="file:$CERT_PASSWORD_FILE"
    fi
    local args=(-in "$CERT_PATH" -passin "$passin")
    # The gateway reads the leaf and the intermediate chain from separate files.
    openssl pkcs12 "${args[@]}" -clcerts -nokeys > "$bundleDir/cert.pem" || return 1
    [[ $(grep -c '^-----BEGIN CERTIFICATE-----$' "$bundleDir/cert.pem") == 1 ]] || return 1
    openssl pkcs12 "${args[@]}" -cacerts -nokeys > "$bundleDir/chain.pem" || return 1
    openssl pkcs12 "${args[@]}" -nocerts -nodes > "$bundleDir/key.pem" || return 1
    [[ $(grep -c '^-----BEGIN PRIVATE KEY-----$' "$bundleDir/key.pem") == 1 ]] || return 1
    cert_public=$(openssl x509 -in "$bundleDir/cert.pem" -pubkey -noout) || return 1
    key_public=$(openssl pkey -in "$bundleDir/key.pem" -pubout) || return 1
    [[ $cert_public == "$key_public" ]]
)

write_gateway_config() {
    # Setting up the configuration file
    configFile="${DOCUMENTDB_CONFIG_FILE:-$(mktemp /tmp/SetupConfiguration_XXXXXX.json)}"
    cp "$CONFIG_DIR/SetupConfiguration.json" "$configFile"
    chmod 600 "$configFile"

    if [ -n "${DOCUMENTDB_PORT:-}" ]; then
        echo "Updating GatewayListenPort in the configuration file..."
        jq ".GatewayListenPort = $DOCUMENTDB_PORT" "$configFile" > "$configFile.tmp" && \
        mv "$configFile.tmp" "$configFile"
    fi

    if [ -n "${POSTGRESQL_PORT:-}" ]; then
        echo "Updating PostgresPort in the configuration file..."
        jq ".PostgresPort = $POSTGRESQL_PORT" "$configFile" > "$configFile.tmp" && \
        mv "$configFile.tmp" "$configFile"
    fi

    local certPath="${CERT_PATH:-}" keyFilePath="${KEY_FILE:-}" caPath=""
    if is_pkcs12_bundle; then
        bundleDir=$(mktemp -d /tmp/documentdb-tls.XXXXXXXX) || exit 1
        if ! extract_pkcs12_bundle; then
            echo "Error: could not load the PKCS#12 certificate, matching key and password." >&2
            exit 1
        fi
        certPath="$bundleDir/cert.pem"
        keyFilePath="$bundleDir/key.pem"
        if [[ -s $bundleDir/chain.pem ]]; then
            caPath="$bundleDir/chain.pem"
        fi
    fi
    if [ -n "$certPath" ] && [ -n "$keyFilePath" ]; then
        echo "Adding CertificateOptions to the configuration file..."
        jq --arg certPath "$certPath" --arg keyFilePath "$keyFilePath" --arg caPath "$caPath" \
            '.CertificateOptions = ({ "CertType": "PemFile", "FilePath": $certPath, "KeyFilePath": $keyFilePath }
                + (if $caPath == "" then {} else { "CaPath": $caPath } end))' \
            "$configFile" > "$configFile.tmp" || exit 1
        mv "$configFile.tmp" "$configFile" || exit 1
    fi

    echo "Setting TLS mode to '$TLS_MODE'..."
    # The gateway has no TlsMode field; only EnforceTls below is read. requireTLS
    # enforces TLS for every connection; allowTLS and disabled let the gateway
    # accept both plain (non-TLS) and TLS clients on the same port.
    if [ "$TLS_MODE" = "requireTLS" ]; then
        enforceTls=true
    else
        enforceTls=false
        if [ "$TLS_MODE" = "disabled" ]; then
            echo "Warning: tlsMode 'disabled' does not turn TLS off. The gateway has no plain-only mode, so it behaves like 'allowTLS' and still accepts TLS connections (plain connections are accepted as well)." >&2
        fi
    fi

    # Fail fast if the EnforceTls write does not succeed: a stale config would leave
    # EnforceTls unset, which the gateway treats as "enforce TLS", silently rejecting
    # the plain connections this setting is meant to allow.
    if ! jq --argjson enforceTls "$enforceTls" '.EnforceTls = $enforceTls' "$configFile" > "$configFile.tmp"; then
        echo "Error: failed to write EnforceTls to the gateway configuration file." >&2
        exit 1
    fi
    mv "$configFile.tmp" "$configFile"

    if [ "${START_POSTGRESQL:-}" = "true" ]; then
        if hostConfigFile="$(mktemp /tmp/documentdb_host_config_XXXXXX.json)" \
                && write_host_config false \
                && jq --arg hostConfig "$hostConfigFile" '.DynamicConfigurationFile = $hostConfig' \
                    "$configFile" > "$configFile.tmp" \
                && mv "$configFile.tmp" "$configFile"; then
            :
        else
            echo "Warning: could not set up the gateway host configuration file; requests will not fail fast while PostgreSQL is down." >&2
            rm -f "${hostConfigFile:-}" "$configFile.tmp"
            hostConfigFile=""
        fi
    fi
}

write_host_config() {
    printf '{"SendShutdownResponses": "%s"}\n' "$1" > "$hostConfigFile.tmp" \
        && chmod 644 "$hostConfigFile.tmp" \
        && mv -f "$hostConfigFile.tmp" "$hostConfigFile"
}
