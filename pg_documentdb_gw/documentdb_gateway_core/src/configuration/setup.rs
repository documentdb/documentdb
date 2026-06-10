/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/setup.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{env, fs::File, path::Path};

use serde::Deserialize;

use crate::{
    configuration::{CertInputType, CertificateOptions, SetupConfiguration},
    error::{DocumentDBError, Result},
    telemetry::config::TelemetryOptions,
};

/// Environment variable names recognized by `DocumentDBSetupConfiguration::from_env`.
///
/// These match the names documented in `oss/packaging/gateway/config/gateway.env`
/// and in `packaging-design.md` §4.3.
pub mod env_keys {
    /// Path to a file containing the `PostgreSQL` connection URL. The file is
    /// read at startup; for Track 1 the URL must not contain a password.
    pub const PG_URL_FILE: &str = "DOCUMENTDB_PG_URL_FILE";
    /// `host:port` or `:port` form for the gateway listener.
    pub const LISTEN_ADDR: &str = "DOCUMENTDB_LISTEN_ADDR";
    /// Path to the TLS certificate file.
    pub const TLS_CERT_FILE: &str = "DOCUMENTDB_TLS_CERT_FILE";
    /// Path to the TLS private key file.
    pub const TLS_KEY_FILE: &str = "DOCUMENTDB_TLS_KEY_FILE";
    /// When true, auto-generate a self-signed cert if no cert/key files are set.
    /// When false, expect cert/key files to be provided.
    pub const TLS_AUTO_GENERATE: &str = "DOCUMENTDB_TLS_AUTO_GENERATE";
    /// Directory under which `DOCUMENTDB_TLS_AUTO_GENERATE=true` writes
    /// (and re-reads on restart) the self-signed `cert.pem` / `pkey.pem`.
    /// Defaults to `/var/lib/documentdb-gateway/tls` when unset.
    ///
    /// This is read directly by the TLS provider in
    /// `service::tls`, not threaded through `DocumentDBSetupConfiguration`,
    /// because the value is used only at TLS bootstrap time and changing
    /// it requires a restart anyway. The constant is declared here so
    /// the full env-var surface lives in one module.
    pub const TLS_STATE_DIR: &str = "DOCUMENTDB_TLS_STATE_DIR";
    /// Log level passed to the tracing subscriber (e.g., "info", "debug").
    pub const LOG_LEVEL: &str = "DOCUMENTDB_LOG_LEVEL";

    // Note: `DOCUMENTDB_STRICT_VERSION_CHECK` was previously parsed into
    // the configuration struct but never enforced anywhere in the
    // gateway runtime (the design's compat-check hook does not exist
    // yet). Removed for Track 1; will be reintroduced together with the
    // actual enforcement logic in a follow-up.
}

// Configurations which are populated statically on process start.
//
// Manual `Debug` impl below (instead of `#[derive(Debug)]`) redacts the
// `postgres_data_user_password` field so a stray `tracing::info!`/`{cfg:?}`
// log line cannot leak a credential. The bgworker variant
// (`pg_documentdb_gw_host`) calls `Self::new` and logs the loaded
// configuration before any explicit rejection runs.
#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct DocumentDBSetupConfiguration {
    pub application_name: Option<String>,
    pub node_host_name: String,
    pub blocked_role_prefixes: Vec<String>,

    // Gateway listener configuration
    pub use_local_host: Option<bool>,
    pub gateway_listen_port: Option<u16>,
    pub enforce_tls: Option<bool>,

    // Postgres configuration
    #[serde(default = "default_user")]
    pub postgres_system_user: String,
    #[serde(default = "default_user")]
    pub postgres_data_user: String,
    pub postgres_data_user_password: Option<String>,
    pub postgres_host_name: Option<String>,
    pub postgres_port: Option<u16>,
    pub postgres_database: Option<String>,

    #[serde(default)]
    pub allow_transaction_snapshot: Option<bool>,
    pub transaction_timeout_secs: Option<u64>,
    pub certificate_options: CertificateOptions,

    #[serde(default)]
    pub dynamic_configuration_file: String,
    pub dynamic_configuration_refresh_interval_secs: Option<u32>,
    pub host_configuration_watch_interval_ms: Option<u64>,
    pub postgres_command_timeout_secs: Option<u64>,
    pub postgres_idle_connection_timeout_minutes: Option<u64>,
    pub postgres_startup_wait_time_seconds: Option<u64>,

    // Runtime configuration
    pub async_runtime_worker_threads: Option<usize>,
    pub stream_read_buffer_size: Option<usize>,
    pub stream_write_buffer_size: Option<usize>,

    // Unix domain socket configuration
    // If specified with a non-empty path, Unix socket is enabled at that path.
    // If not specified (None), Unix socket is disabled.
    pub unix_socket_path: Option<String>,

    // Unix socket file permissions (octal format string, e.g., "0660" for owner+group read/write)
    // If not specified, defaults to 0o660
    pub unix_socket_file_permissions: Option<String>,

    // Kind identifier for this gateway instance, included in hello command response.
    pub instance_kind: Option<String>,

    // Telemetry configuration
    pub telemetry_options: Option<TelemetryOptions>,

    // Whether to enable refreshing settings from pg_file_settings
    pub enable_pg_file_settings_refresh: Option<bool>,
    // Note: `strict_version_check` was previously declared here and
    // populated from DOCUMENTDB_STRICT_VERSION_CHECK, but never enforced.
    // Removed for Track 1; will return alongside the actual extension-
    // version compatibility check implementation.
}

impl std::fmt::Debug for DocumentDBSetupConfiguration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Mirrors the previous `#[derive(Debug)]` layout but redacts
        // `postgres_data_user_password` so the credential is never
        // emitted via `{cfg:?}` logging. The bgworker variant
        // (`pg_documentdb_gw_host`) calls `Self::new` and logs the
        // loaded configuration before any explicit rejection runs, so
        // a derived Debug would leak.
        let password = if self.postgres_data_user_password.is_some() {
            "Some(\"<redacted>\")"
        } else {
            "None"
        };
        f.debug_struct("DocumentDBSetupConfiguration")
            .field("application_name", &self.application_name)
            .field("node_host_name", &self.node_host_name)
            .field("blocked_role_prefixes", &self.blocked_role_prefixes)
            .field("use_local_host", &self.use_local_host)
            .field("gateway_listen_port", &self.gateway_listen_port)
            .field("enforce_tls", &self.enforce_tls)
            .field("postgres_system_user", &self.postgres_system_user)
            .field("postgres_data_user", &self.postgres_data_user)
            .field("postgres_data_user_password", &format_args!("{password}"))
            .field("postgres_host_name", &self.postgres_host_name)
            .field("postgres_port", &self.postgres_port)
            .field("postgres_database", &self.postgres_database)
            .field(
                "allow_transaction_snapshot",
                &self.allow_transaction_snapshot,
            )
            .field("transaction_timeout_secs", &self.transaction_timeout_secs)
            .field("certificate_options", &self.certificate_options)
            .field(
                "dynamic_configuration_file",
                &self.dynamic_configuration_file,
            )
            .field(
                "dynamic_configuration_refresh_interval_secs",
                &self.dynamic_configuration_refresh_interval_secs,
            )
            .field(
                "host_configuration_watch_interval_ms",
                &self.host_configuration_watch_interval_ms,
            )
            .field(
                "postgres_command_timeout_secs",
                &self.postgres_command_timeout_secs,
            )
            .field(
                "postgres_idle_connection_timeout_minutes",
                &self.postgres_idle_connection_timeout_minutes,
            )
            .field(
                "postgres_startup_wait_time_seconds",
                &self.postgres_startup_wait_time_seconds,
            )
            .field(
                "async_runtime_worker_threads",
                &self.async_runtime_worker_threads,
            )
            .field("stream_read_buffer_size", &self.stream_read_buffer_size)
            .field("stream_write_buffer_size", &self.stream_write_buffer_size)
            .field("unix_socket_path", &self.unix_socket_path)
            .field(
                "unix_socket_file_permissions",
                &self.unix_socket_file_permissions,
            )
            .field("instance_kind", &self.instance_kind)
            .field("telemetry_options", &self.telemetry_options)
            .field(
                "enable_pg_file_settings_refresh",
                &self.enable_pg_file_settings_refresh,
            )
            .finish()
    }
}

impl DocumentDBSetupConfiguration {
    /// Load configuration strictly from a JSON file.
    ///
    /// Kept for back-compat with existing callers (tests, dev tooling) and
    /// for the embedded `pg_documentdb_gw_host` background-worker variant.
    /// New runtime callers should prefer [`Self::from_env_with_optional_json`]
    /// which also overlays the env-var settings documented in
    /// `packaging-design.md` §4.3.
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn new(config_path: &Path) -> Result<Self> {
        let config_file = File::open(config_path)?;
        let config: Self = serde_json::from_reader(config_file).map_err(|e| {
            DocumentDBError::internal_error(format!("Failed to parse configuration file: {e}"))
        })?;

        Self::validate_unix_socket(&config)?;
        Ok(config)
    }

    /// Load configuration with env-var overlays on top of an optional JSON
    /// file. This is the Track 1 entry point used by the packaged gateway
    /// service: `EnvironmentFile=-/etc/documentdb/gateway/gateway.env` makes
    /// the JSON file optional, and env vars carry every setting the
    /// packaging design documents.
    ///
    /// Overlay order: defaults → JSON (if present) → env vars (if set) →
    /// `DOCUMENTDB_PG_URL_FILE` (if set, decomposed into host/port/db/user).
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON file fails to parse, if an env var has
    /// an invalid value, or if the resolved `PostgreSQL` URL carries a
    /// password (rejected for Track 1 — see `packaging-design.md` §4.3 and
    /// §7).
    pub fn from_env_with_optional_json(config_path: Option<&Path>) -> Result<Self> {
        let mut config = match config_path {
            None => Self::default(),
            Some(path) if path.exists() => Self::new(path)?,
            Some(path) => {
                // PR-Assistant security finding (Iter5): silently
                // treating `Some(missing_path)` as `None` masks a
                // mistyped or missing config-file path at non-main
                // call sites. The binary path additionally guards
                // this in main::load_configuration, but the lib
                // function must fail loudly so future callers
                // (tests, embedded variants) don't get the silent
                // default-fallback behavior.
                return Err(DocumentDBError::internal_error(format!(
                    "Configuration file does not exist: {}",
                    path.display()
                )));
            }
        };

        // `Self::default()` leaves `postgres_system_user` and
        // `postgres_data_user` as empty strings because the
        // `#[serde(default = "default_user")]` only fires during JSON
        // deserialization. The env-only path (no JSON loaded) would
        // otherwise pass an empty username to the PostgreSQL connection
        // pool. Populate them defensively before overlaying env / URL
        // overrides — if those overrides supply a user, this is a no-op
        // (env overlay overwrites unconditionally); if they don't, the
        // gateway connects as the OS user, matching libpq's default and
        // the JSON-path behavior.
        if config.postgres_system_user.is_empty() {
            config.postgres_system_user = default_user();
        }
        if config.postgres_data_user.is_empty() {
            config.postgres_data_user = default_user();
        }

        Self::apply_env_overlays(&mut config)?;
        Self::validate_unix_socket(&config)?;
        Self::reject_password_environment()?;
        Self::reject_password_in_config(&config)?;

        Ok(config)
    }

    fn validate_unix_socket(config: &Self) -> Result<()> {
        if let Some(path) = &config.unix_socket_path {
            if path.trim().is_empty() {
                return Err(DocumentDBError::internal_error(
                    "UnixSocketPath cannot be empty. Either provide a valid path or omit the field to disable Unix sockets.".to_owned()
                ));
            }
        }

        if let Some(perm_str) = &config.unix_socket_file_permissions {
            if u32::from_str_radix(perm_str, 8).is_err() {
                return Err(DocumentDBError::internal_error(
                    format!("Invalid UnixSocketFilePermissions '{perm_str}'. Expected octal format like '0600', '0644'")
                ));
            }
        }
        Ok(())
    }

    fn reject_password_environment() -> Result<()> {
        // PGPASSWORD would leak through libpq via /proc/<pid>/environ on
        // multi-tenant hosts. This build of the gateway only supports
        // passwordless local peer auth; a dedicated *_FILE indirection
        // will be introduced when password-bearing connections are added.
        //
        // We treat an empty PGPASSWORD ("") as absent because libpq
        // does the same — that way operators (and tests) can null out
        // an inherited PGPASSWORD via `unset` or `=""` without hitting
        // a confusing "rejected" error for what is functionally an
        // empty value.
        if let Some(v) = env::var_os("PGPASSWORD") {
            if !v.is_empty() {
                return Err(DocumentDBError::internal_error(
                    "PGPASSWORD is set in the gateway environment but this build only supports passwordless local peer auth. Unset PGPASSWORD or use the documented Unix-socket setup.".to_owned(),
                ));
            }
        }
        Ok(())
    }

    // Reviewer-flagged (external review iter 18): the JSON schema
    // carries a `PostgresDataUserPassword` field (legacy field for
    // password-bearing PostgreSQL backends). Passwords are rejected
    // end-to-end; the env-var rejection above only covers PGPASSWORD,
    // the URL-file parser rejects passwords in DOCUMENTDB_PG_URL_FILE
    // contents, but the JSON path was a bypass: hand-editing
    // /etc/documentdb/gateway/SetupConfiguration.json to set
    // PostgresDataUserPassword would silently load. Reject any
    // password value reaching us through JSON too. This runs after
    // both JSON load and env overlay so it covers every path.
    fn reject_password_in_config(config: &Self) -> Result<()> {
        if config.postgres_data_user_password.is_some() {
            return Err(DocumentDBError::internal_error(
                "PostgresDataUserPassword is set in the JSON configuration file but this build only supports passwordless local peer auth; the field is rejected. \
                 Remove it from /etc/documentdb/gateway/SetupConfiguration.json and use Unix-socket / peer-auth connection settings instead."
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn apply_env_overlays(config: &mut Self) -> Result<()> {
        if let Some(addr) = read_env(env_keys::LISTEN_ADDR)? {
            let (host, port) = parse_listen_addr(&addr)?;
            if let Some(port) = port {
                config.gateway_listen_port = Some(port);
            }
            // The runtime listener configuration only carries a
            // `use_local_host: bool` (loopback-only vs all-interfaces) —
            // it cannot currently bind to a specific non-loopback IP.
            // If we silently accepted an explicit IP we'd bind all
            // interfaces, which is a strictly broader exposure than
            // the operator asked for. Reject explicit non-loopback
            // hosts and direct the operator to either the `:port`
            // form (all interfaces) or `127.0.0.1:port` /
            // `localhost:port` / `[::1]:port` (loopback only).
            let normalized_host = host.as_deref();
            match normalized_host {
                None | Some("" | "127.0.0.1" | "::1" | "localhost") => {
                    config.use_local_host = Some(matches!(
                        normalized_host,
                        Some("127.0.0.1" | "::1" | "localhost")
                    ));
                }
                Some(other) => {
                    return Err(DocumentDBError::internal_error(format!(
                        "{addr_env}={addr}: explicit bind address {other:?} is not supported. \
                         Use ':{p}' for all interfaces or '127.0.0.1:{p}' / 'localhost:{p}' / '[::1]:{p}' for loopback only.",
                        addr_env = env_keys::LISTEN_ADDR,
                        p = port.unwrap_or(10260)
                    )));
                }
            }
        }

        let cert = read_env(env_keys::TLS_CERT_FILE)?;
        let key = read_env(env_keys::TLS_KEY_FILE)?;
        let auto_generate = read_env_bool(env_keys::TLS_AUTO_GENERATE)?;

        if cert.is_some() || key.is_some() || auto_generate.is_some() {
            apply_tls_overlay(&mut config.certificate_options, cert, key, auto_generate)?;
        }

        if let Some(url_file) = read_env(env_keys::PG_URL_FILE)? {
            apply_pg_url_file(config, Path::new(&url_file))?;
        }

        // Reviewer-flagged (external review iter 17): per the packaging
        // design, when no TLS cert/key paths are supplied AND the
        // operator has not set DOCUMENTDB_TLS_AUTO_GENERATE explicitly,
        // the documented default is auto-generated self-signed certs.
        // Without this pass the env-only install (no JSON, no TLS env
        // vars) leaves certificate_options at CertInputType::PemFile
        // with both file paths None — TlsProvider::new then fails in
        // main.rs at startup. Switch to PemAutoGenerated so the
        // documented default is actually the default.
        //
        // We always emit a warning when this fallback triggers because
        // there is no way to distinguish "JSON explicitly set
        // CertType=PemFile and forgot paths" from "no config supplied,
        // hitting Default". An operator who deliberately wants auto-gen
        // should set DOCUMENTDB_TLS_AUTO_GENERATE=true to silence the
        // warning; one who intended PemFile mode will see the warning
        // in journalctl and fix their config.
        if matches!(config.certificate_options.cert_type, CertInputType::PemFile)
            && config.certificate_options.file_path.is_none()
            && config.certificate_options.key_file_path.is_none()
        {
            tracing::warn!(
                "CertificateOptions resolved to CertType=PemFile with neither FilePath nor KeyFilePath set. \
                 Falling back to auto-generated self-signed certificates. Set {cert_env} and {key_env}, \
                 or {auto_env}=true to silence this warning, if a specific TLS posture was intended.",
                cert_env = env_keys::TLS_CERT_FILE,
                key_env = env_keys::TLS_KEY_FILE,
                auto_env = env_keys::TLS_AUTO_GENERATE,
            );
            config.certificate_options.cert_type = CertInputType::PemAutoGenerated;
        }

        Ok(())
    }
}

/// Apply `DOCUMENTDB_PG_URL_FILE` overlay.
///
/// The file is expected to contain a single `postgresql://` URL. We parse
/// the host (file path for Unix-socket style, hostname for TCP), port,
/// database, and user from the URL and reject any URL carrying a password.
///
/// On Unix the file's permission mode is also checked: world-readable or
/// world-writable files emit a `tracing::warn!` (but do not block
/// startup). The packaging design specifies `root:documentdb-gateway 0640`
/// for this file; admins who hand-roll it should respect the same.
fn apply_pg_url_file(config: &mut DocumentDBSetupConfiguration, path: &Path) -> Result<()> {
    let raw = std::fs::read_to_string(path).map_err(|e| {
        DocumentDBError::internal_error(format!(
            "Failed to read DOCUMENTDB_PG_URL_FILE {}: {}",
            path.display(),
            e
        ))
    })?;

    warn_if_url_file_too_permissive(path);

    let url = raw.trim();
    if url.is_empty() {
        return Err(DocumentDBError::internal_error(format!(
            "DOCUMENTDB_PG_URL_FILE {} is empty",
            path.display()
        )));
    }

    let parsed = ParsedPgUrl::parse(url)?;
    if parsed.has_password {
        return Err(DocumentDBError::internal_error(
            "Password-bearing PostgreSQL URLs in DOCUMENTDB_PG_URL_FILE are not supported. Use peer auth on a local Unix socket instead.".to_owned(),
        ));
    }

    if let Some(host) = parsed.host {
        config.postgres_host_name = Some(host);
    }
    if let Some(port) = parsed.port {
        config.postgres_port = Some(port);
    }
    if let Some(db) = parsed.database {
        config.postgres_database = Some(db);
    }
    if let Some(user) = parsed.user {
        config.postgres_data_user.clone_from(&user);
        config.postgres_system_user = user;
    }
    // Note: `parsed.unix_socket_dir` is intentionally NOT assigned to
    // `config.unix_socket_path`. The latter controls the gateway's own
    // client-facing Unix socket listener (see `create_unix_socket_listener`
    // in lib.rs), while the PG URL's socket directory identifies where
    // PostgreSQL listens. The PG connection already uses
    // `postgres_host_name` (set above) which tokio-postgres interprets as
    // a Unix socket directory when the value starts with '/'. Setting
    // `unix_socket_path` here would make the gateway attempt to bind its
    // own listener at the PostgreSQL socket directory, crashing on start.

    Ok(())
}

/// Emit a `tracing::warn!` if the PG URL file is more permissive than
/// the packaging design's documented `0640`. The packaged install ships
/// the file as `root:documentdb-gateway 0640`; hand-rolled installs that
/// leave it world-readable expose connection topology (host, port, user,
/// database) to any local user. We warn rather than refuse so that
/// `chmod`-restricted environments (NFS / CIFS without Unix perms) can
/// still operate.
#[cfg(unix)]
fn warn_if_url_file_too_permissive(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(meta) => {
            let mode = meta.permissions().mode() & 0o777;
            if mode & 0o007 != 0 {
                tracing::warn!(
                    "DOCUMENTDB_PG_URL_FILE {} has mode {:#o}, which is readable by other users. \
                     Recommended permissions are 0640 owned by root:documentdb-gateway. \
                     Use 'chmod 0640 {}' to tighten.",
                    path.display(),
                    mode,
                    path.display(),
                );
            } else if mode & 0o020 != 0 {
                tracing::warn!(
                    "DOCUMENTDB_PG_URL_FILE {} has mode {:#o}, which is group-writable. \
                     Recommended permissions are 0640 owned by root:documentdb-gateway.",
                    path.display(),
                    mode,
                );
            }
        }
        Err(e) => {
            tracing::warn!(
                "Could not stat DOCUMENTDB_PG_URL_FILE {} to check permissions: {}",
                path.display(),
                e
            );
        }
    }
}

#[cfg(not(unix))]
fn warn_if_url_file_too_permissive(_path: &Path) {
    // No filesystem-mode concept on Windows; the packaged install path
    // is Linux-only so this is a no-op.
}

#[derive(Debug, Default)]
struct ParsedPgUrl {
    host: Option<String>,
    port: Option<u16>,
    database: Option<String>,
    user: Option<String>,
    unix_socket_dir: Option<String>,
    has_password: bool,
}

impl ParsedPgUrl {
    fn parse(raw: &str) -> Result<Self> {
        // Accept both postgres:// and postgresql:// prefixes.
        let rest = raw
            .strip_prefix("postgresql://")
            .or_else(|| raw.strip_prefix("postgres://"))
            .ok_or_else(|| {
                DocumentDBError::internal_error(format!(
                    "PostgreSQL connection URL must start with postgresql:// (got: {raw})"
                ))
            })?;

        let mut parsed = Self::default();

        let (userinfo, host_part) = match rest.find('@') {
            Some(at) => (Some(&rest[..at]), &rest[at + 1..]),
            None => (None, rest),
        };

        if let Some(info) = userinfo {
            if let Some((user, _password)) = info.split_once(':') {
                // The presence of the colon in userinfo signals a
                // password segment; both `user:password@` and `:secret@`
                // (empty user) and `user:@` (empty password) all mean
                // "the URL is shaped like it carries credentials" and
                // are rejected by the passwordless URL policy.
                parsed.has_password = true;
                parsed.user = if user.is_empty() {
                    None
                } else {
                    Some(percent_decode(user))
                };
            } else {
                parsed.user = Some(percent_decode(info));
            }
        }

        // Drop query string before further parsing.
        let (host_and_path, query) = match host_part.find('?') {
            Some(q) => (&host_part[..q], Some(&host_part[q + 1..])),
            None => (host_part, None),
        };

        // libpq's URL form recognizes a leading slash in the host segment
        // as a Unix socket directory only when percent-encoded (%2F). A
        // literal "/" begins the dbname/path component. We therefore
        // accept the well-formed libpq forms:
        //   postgresql://user@host:port/dbname
        //   postgresql://user@%2Fsock%2Fdir:port/dbname
        //   postgresql://user@/dbname?host=/sock/dir&port=NNNN
        let (hostport, db) = match host_and_path.find('/') {
            Some(slash) => (&host_and_path[..slash], Some(&host_and_path[slash + 1..])),
            None => (host_and_path, None),
        };
        if let Some(db) = db {
            if !db.is_empty() {
                parsed.database = Some(percent_decode(db));
            }
        }

        // Split host and port. RFC 3986 IPv6 literals are bracketed
        // (`[::1]:port` or `[::1]`), so we delegate to a small helper
        // that also handles the bare `host:port` and `host` forms.
        let (host_raw, port_raw) = split_host_port(hostport)?;
        if let Some(port_str) = port_raw {
            if !port_str.is_empty() {
                let port: u16 = port_str.parse().map_err(|e| {
                    DocumentDBError::internal_error(format!(
                        "Invalid port in URL ({port_str}): {e}"
                    ))
                })?;
                parsed.port = Some(port);
            }
        }

        if !host_raw.is_empty() {
            let host = percent_decode(host_raw);
            // After percent-decode, a host starting with "/" is a Unix
            // socket directory (libpq convention).
            if host.starts_with('/') {
                parsed.unix_socket_dir = Some(host.clone());
            }
            parsed.host = Some(host);
        }

        // Apply query parameters last so they can override / supply
        // host+port for the libpq Unix-socket convention.
        if let Some(q) = query {
            for kv in q.split('&') {
                let Some((k, v)) = kv.split_once('=') else {
                    continue;
                };
                let decoded = percent_decode(v);
                if k.eq_ignore_ascii_case("password") {
                    parsed.has_password = true;
                } else if k.eq_ignore_ascii_case("host") {
                    if decoded.starts_with('/') {
                        parsed.unix_socket_dir = Some(decoded.clone());
                    }
                    parsed.host = Some(decoded);
                } else if k.eq_ignore_ascii_case("port") {
                    let port: u16 = decoded.parse().map_err(|e| {
                        DocumentDBError::internal_error(format!(
                            "Invalid port in URL query ({decoded}): {e}"
                        ))
                    })?;
                    parsed.port = Some(port);
                }
            }
        }

        Ok(parsed)
    }
}

/// Splits the host/port segment of a `PostgreSQL` URL. Handles the three
/// forms libpq accepts: bracketed IPv6 (`[::1]` and `[::1]:port`), bare
/// hostname or socket dir (`host`), and `host:port`. Returns
/// `(host, optional_port_str)` where `port_str` is the raw text that
/// still needs to be `u16::parse`d by the caller.
fn split_host_port(hostport: &str) -> Result<(&str, Option<&str>)> {
    if let Some(rest) = hostport.strip_prefix('[') {
        let close = rest.find(']').ok_or_else(|| {
            DocumentDBError::internal_error(format!(
                "Unterminated '[' in PostgreSQL URL host: {hostport}"
            ))
        })?;
        let host = &rest[..close];
        let after = &rest[close + 1..];
        let port = if let Some(p) = after.strip_prefix(':') {
            Some(p)
        } else if after.is_empty() {
            None
        } else {
            return Err(DocumentDBError::internal_error(format!(
                "Unexpected content after ']' in PostgreSQL URL host: {hostport}"
            )));
        };
        Ok((host, port))
    } else {
        Ok(match hostport.rfind(':') {
            Some(colon) => (&hostport[..colon], Some(&hostport[colon + 1..])),
            None => (hostport, None),
        })
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_digit(bytes[i + 1]), hex_digit(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

const fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn parse_listen_addr(raw: &str) -> Result<(Option<String>, Option<u16>)> {
    // Accept "host:port", ":port", "[::1]:port", or bare "port".
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok((None, None));
    }
    if let Some(rest) = trimmed.strip_prefix('[') {
        // IPv6 bracketed form
        let close = rest.find(']').ok_or_else(|| {
            DocumentDBError::internal_error(format!("Unterminated '[' in listen addr: {raw}"))
        })?;
        let host = rest[..close].to_owned();
        let after = &rest[close + 1..];
        let port = after
            .strip_prefix(':')
            .map(str::parse::<u16>)
            .transpose()
            .map_err(|e| {
                DocumentDBError::internal_error(format!("Invalid port in listen addr ({raw}): {e}"))
            })?;
        return Ok((Some(host), port));
    }
    if let Some(idx) = trimmed.rfind(':') {
        let host = if idx == 0 {
            None
        } else {
            Some(trimmed[..idx].to_owned())
        };
        let port_str = &trimmed[idx + 1..];
        let port: u16 = port_str.parse().map_err(|e| {
            DocumentDBError::internal_error(format!("Invalid port in listen addr ({raw}): {e}"))
        })?;
        Ok((host, Some(port)))
    } else {
        // Bare port (no colon) — uncommon but accept it.
        let port: u16 = trimmed.parse().map_err(|e| {
            DocumentDBError::internal_error(format!("Invalid listen addr ({raw}): {e}"))
        })?;
        Ok((None, Some(port)))
    }
}

fn apply_tls_overlay(
    options: &mut CertificateOptions,
    cert: Option<String>,
    key: Option<String>,
    auto_generate: Option<bool>,
) -> Result<()> {
    // If either cert or key file is provided, we are in PemFile mode and
    // both must be set.
    if cert.is_some() || key.is_some() {
        let cert = cert.ok_or_else(|| {
            DocumentDBError::internal_error(format!(
                "{} requires {} to also be set",
                env_keys::TLS_KEY_FILE,
                env_keys::TLS_CERT_FILE
            ))
        })?;
        let key = key.ok_or_else(|| {
            DocumentDBError::internal_error(format!(
                "{} requires {} to also be set",
                env_keys::TLS_CERT_FILE,
                env_keys::TLS_KEY_FILE
            ))
        })?;
        options.cert_type = CertInputType::PemFile;
        options.file_path = Some(cert);
        options.key_file_path = Some(key);

        // If both cert/key are set, DOCUMENTDB_TLS_AUTO_GENERATE=true is a
        // user error — they cannot both apply. We honor the explicit cert
        // and log a warning at runtime; here we just refuse.
        if matches!(auto_generate, Some(true)) {
            return Err(DocumentDBError::internal_error(format!(
                "{}=true conflicts with {}/{}; pick one TLS source",
                env_keys::TLS_AUTO_GENERATE,
                env_keys::TLS_CERT_FILE,
                env_keys::TLS_KEY_FILE
            )));
        }
    } else if matches!(auto_generate, Some(true)) {
        options.cert_type = CertInputType::PemAutoGenerated;
        options.file_path = None;
        options.key_file_path = None;
    } else if matches!(auto_generate, Some(false)) {
        // Explicit opt-out with no cert/key paths is invalid.
        return Err(DocumentDBError::internal_error(format!(
            "{}=false requires {} and {} to be set",
            env_keys::TLS_AUTO_GENERATE,
            env_keys::TLS_CERT_FILE,
            env_keys::TLS_KEY_FILE
        )));
    }
    Ok(())
}

fn read_env(key: &str) -> Result<Option<String>> {
    match env::var(key) {
        Ok(v) => {
            let trimmed = v.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_owned()))
            }
        }
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(_)) => Err(DocumentDBError::internal_error(format!(
            "Environment variable {key} is not valid UTF-8"
        ))),
    }
}

fn read_env_bool(key: &str) -> Result<Option<bool>> {
    match read_env(key)? {
        None => Ok(None),
        Some(v) => match v.to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" | "on" => Ok(Some(true)),
            "false" | "0" | "no" | "off" => Ok(Some(false)),
            other => Err(DocumentDBError::internal_error(format!(
                "Environment variable {key} must be a boolean (true/false), got: {other}"
            ))),
        },
    }
}

fn default_user() -> String {
    whoami::username()
}

impl SetupConfiguration for DocumentDBSetupConfiguration {
    // Needed to downcast to concrete type
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn postgres_host_name(&self) -> &str {
        self.postgres_host_name.as_deref().unwrap_or("localhost")
    }

    fn postgres_port(&self) -> u16 {
        self.postgres_port.unwrap_or(9712)
    }

    fn postgres_database(&self) -> &str {
        self.postgres_database.as_deref().unwrap_or("postgres")
    }

    fn postgres_system_user(&self) -> &str {
        &self.postgres_system_user
    }

    fn postgres_data_user(&self) -> &str {
        &self.postgres_data_user
    }

    fn postgres_data_user_password(&self) -> Option<&str> {
        self.postgres_data_user_password.as_deref()
    }

    fn dynamic_configuration_file(&self) -> String {
        self.dynamic_configuration_file.clone()
    }

    fn dynamic_configuration_refresh_interval_secs(&self) -> u32 {
        self.dynamic_configuration_refresh_interval_secs
            .unwrap_or(60 * 5)
    }

    fn host_configuration_watch_interval_ms(&self) -> u64 {
        self.host_configuration_watch_interval_ms.unwrap_or(1000)
    }

    fn transaction_timeout_secs(&self) -> u64 {
        self.transaction_timeout_secs.unwrap_or(30)
    }

    fn use_local_host(&self) -> bool {
        self.use_local_host.unwrap_or(false)
    }

    fn gateway_listen_port(&self) -> u16 {
        self.gateway_listen_port.unwrap_or(10260)
    }

    fn blocked_role_prefixes(&self) -> &[String] {
        &self.blocked_role_prefixes
    }

    fn postgres_command_timeout_secs(&self) -> u64 {
        self.postgres_command_timeout_secs.unwrap_or(120)
    }

    fn certificate_options(&self) -> &CertificateOptions {
        &self.certificate_options
    }

    fn node_host_name(&self) -> &str {
        &self.node_host_name
    }

    fn application_name(&self) -> &str {
        self.application_name
            .as_deref()
            .unwrap_or("DocumentDBGateway")
    }

    fn postgres_startup_wait_time_seconds(&self) -> u64 {
        self.postgres_startup_wait_time_seconds.unwrap_or(60)
    }

    fn async_runtime_worker_threads(&self) -> usize {
        self.async_runtime_worker_threads.unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(std::num::NonZero::get)
                .unwrap_or(1)
        })
    }

    fn stream_read_buffer_size(&self) -> usize {
        self.stream_read_buffer_size.unwrap_or(8 * 1024)
    }

    fn stream_write_buffer_size(&self) -> usize {
        self.stream_write_buffer_size.unwrap_or(8 * 1024)
    }

    fn unix_socket_path(&self) -> Option<&str> {
        self.unix_socket_path.as_deref()
    }

    fn postgres_idle_connection_timeout_minutes(&self) -> u64 {
        self.postgres_idle_connection_timeout_minutes.unwrap_or(5)
    }

    fn enforce_tls(&self) -> bool {
        self.enforce_tls.unwrap_or(true)
    }

    #[expect(clippy::unwrap_used, reason = "validated octal string")]
    fn unix_socket_file_permissions(&self) -> u32 {
        match &self.unix_socket_file_permissions {
            None => 0o660, // Default when not provided
            Some(perm_str) => u32::from_str_radix(perm_str, 8).unwrap(),
        }
    }

    fn instance_kind(&self) -> &str {
        self.instance_kind.as_deref().unwrap_or("")
    }

    fn telemetry_options(&self) -> Option<&TelemetryOptions> {
        self.telemetry_options.as_ref()
    }

    fn enable_pg_file_settings_refresh(&self) -> Option<bool> {
        self.enable_pg_file_settings_refresh
    }
}

impl DocumentDBSetupConfiguration {
    /// Returns the telemetry options from the configuration, if present.
    #[must_use]
    pub const fn telemetry_options(&self) -> Option<&TelemetryOptions> {
        self.telemetry_options.as_ref()
    }
}

#[cfg(test)]
#[path = "setup_tests.rs"]
mod tests;
