/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/setup_tests.rs
 *
 * Test module for setup.rs. Pulled into setup.rs via:
 *   #[cfg(test)] #[path = "setup_tests.rs"] mod tests;
 * so the test module is still a child of `setup` and retains private-item
 * access via `use super::*;` with zero visibility changes.
 *-------------------------------------------------------------------------
 */

use super::*;
use std::path::PathBuf;

/// Minimal in-test replacement for `tempfile::NamedTempFile`. Creates a
/// uniquely-named file under `std::env::temp_dir()` with the given
/// contents, exposes its path, and removes it on Drop (so the file is
/// cleaned up even on test panic). Lives here rather than in a shared
/// helper crate because it's a 20-line convenience used only by this
/// test module and we want to keep production dev-deps to a minimum.
struct TempPath {
    path: PathBuf,
}

impl TempPath {
    fn with_content(content: &[u8]) -> Self {
        let path = std::env::temp_dir().join(format!(
            "documentdb-gateway-setup-test-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, content).expect("failed to write temp file");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[test]
fn parses_listen_addr_with_host_and_port() {
    let (host, port) = parse_listen_addr("127.0.0.1:10260").unwrap();
    assert_eq!(host.as_deref(), Some("127.0.0.1"));
    assert_eq!(port, Some(10260));
}

#[test]
fn parses_listen_addr_bare_port_form() {
    let (host, port) = parse_listen_addr(":27017").unwrap();
    assert_eq!(host, None);
    assert_eq!(port, Some(27017));
}

#[test]
fn parses_listen_addr_ipv6_bracketed() {
    let (host, port) = parse_listen_addr("[::1]:10260").unwrap();
    assert_eq!(host.as_deref(), Some("::1"));
    assert_eq!(port, Some(10260));
}

#[test]
fn rejects_listen_addr_with_invalid_port() {
    parse_listen_addr("localhost:notaport").unwrap_err();
}

#[test]
fn parses_pg_url_basic() {
    // libpq Unix-socket form via host=... query param (avoids the
    // ambiguity of a literal slash in the host segment).
    let parsed = ParsedPgUrl::parse(
        "postgresql://documentdb-gateway@/postgres?host=/run/documentdb-local/18/postgresql&port=9718",
    )
    .unwrap();
    assert_eq!(parsed.user.as_deref(), Some("documentdb-gateway"));
    assert_eq!(parsed.port, Some(9718));
    assert_eq!(parsed.database.as_deref(), Some("postgres"));
    assert!(!parsed.has_password);
    assert_eq!(
        parsed.unix_socket_dir.as_deref(),
        Some("/run/documentdb-local/18/postgresql")
    );
}

#[test]
fn parses_pg_url_with_percent_encoded_socket_host() {
    let parsed = ParsedPgUrl::parse(
        "postgresql://documentdb-gateway@%2Frun%2Fdocumentdb-local%2F18%2Fpostgresql:9718/postgres",
    )
    .unwrap();
    assert_eq!(parsed.port, Some(9718));
    assert_eq!(parsed.database.as_deref(), Some("postgres"));
    assert_eq!(
        parsed.unix_socket_dir.as_deref(),
        Some("/run/documentdb-local/18/postgresql")
    );
}

#[test]
fn rejects_pg_url_with_userinfo_password() {
    let parsed = ParsedPgUrl::parse("postgresql://alice:secret@dbhost:5432/mydb").unwrap();
    assert!(parsed.has_password);
}

#[test]
fn rejects_postgres_data_user_password_in_config() {
    // The JSON schema includes a `PostgresDataUserPassword` field
    // (legacy support for password-bearing backends). Passwords are
    // rejected end-to-end. PGPASSWORD env and URL-file passwords were
    // already rejected; this test guards the JSON-load bypass — a
    // hand-edited SetupConfiguration.json with this field set must
    // fail closed at startup with a clear error, not silently load.
    let cfg = DocumentDBSetupConfiguration {
        postgres_data_user_password: Some("hunter2".to_owned()),
        ..Default::default()
    };
    let err = DocumentDBSetupConfiguration::reject_password_in_config(&cfg).unwrap_err();
    let msg = format!("{err:?}");
    assert!(
        msg.contains("PostgresDataUserPassword"),
        "error must name the rejected field; got: {msg}",
    );
    assert!(
        msg.contains("passwordless"),
        "error must explain this is the passwordless-only policy; got: {msg}",
    );
}

#[test]
fn accepts_config_without_postgres_password() {
    let cfg = DocumentDBSetupConfiguration::default();
    assert!(cfg.postgres_data_user_password.is_none());
    DocumentDBSetupConfiguration::reject_password_in_config(&cfg).unwrap();
}

#[test]
fn rejects_pg_url_with_empty_user_password_only() {
    // Edge case: a URL with no user but a password segment
    // (postgresql://:secret@host/db) must still be detected as
    // password-bearing. The previous implementation used
    // `!user.is_empty()` which silently let this through.
    let parsed = ParsedPgUrl::parse("postgresql://:secret@dbhost:5432/mydb").unwrap();
    assert!(parsed.has_password);
}

#[test]
fn rejects_pg_url_with_empty_password_segment() {
    // An empty password segment ("user:@host") is still credential-shaped
    // and must be rejected by the passwordless URL policy.
    let parsed = ParsedPgUrl::parse("postgresql://alice:@dbhost:5432/mydb").unwrap();
    assert!(parsed.has_password);
}

#[test]
fn rejects_pg_url_with_query_password() {
    let parsed = ParsedPgUrl::parse("postgresql://alice@dbhost:5432/mydb?password=secret").unwrap();
    assert!(parsed.has_password);
}

#[test]
fn rejects_pg_url_without_known_scheme() {
    ParsedPgUrl::parse("mysql://localhost/x").unwrap_err();
}

#[test]
fn parses_pg_url_with_ipv6_bracketed_host() {
    // Regression: `rfind(':')` on a bracketed IPv6 literal previously
    // landed inside the literal and produced a bogus "invalid port".
    let parsed = ParsedPgUrl::parse("postgresql://alice@[::1]:5432/mydb").unwrap();
    assert_eq!(parsed.host.as_deref(), Some("::1"));
    assert_eq!(parsed.port, Some(5432));
    assert_eq!(parsed.user.as_deref(), Some("alice"));
    assert_eq!(parsed.database.as_deref(), Some("mydb"));
    assert!(!parsed.has_password);
}

#[test]
fn parses_pg_url_with_ipv6_bracketed_host_no_port() {
    let parsed = ParsedPgUrl::parse("postgresql://alice@[2001:db8::1]/mydb").unwrap();
    assert_eq!(parsed.host.as_deref(), Some("2001:db8::1"));
    assert_eq!(parsed.port, None);
    assert_eq!(parsed.database.as_deref(), Some("mydb"));
}

#[test]
fn rejects_pg_url_with_unterminated_ipv6_bracket() {
    let err = ParsedPgUrl::parse("postgresql://alice@[::1/mydb").unwrap_err();
    assert!(format!("{err:?}").contains("Unterminated"));
}

#[test]
fn debug_impl_redacts_postgres_data_user_password() {
    // The DocumentDBSetupConfiguration Debug output is logged at
    // gateway startup (and elsewhere). A derived Debug would leak
    // the password to journald / log shippers; the manual impl
    // must redact.
    let cfg = DocumentDBSetupConfiguration {
        postgres_data_user_password: Some("hunter2".to_owned()),
        ..Default::default()
    };
    let dbg = format!("{cfg:?}");
    assert!(
        !dbg.contains("hunter2"),
        "Debug output must not contain the password literal; got: {dbg}",
    );
    assert!(
        dbg.contains("<redacted>"),
        "Debug output must indicate a password is set but redacted; got: {dbg}",
    );
}

#[test]
fn debug_impl_shows_none_when_password_absent() {
    let cfg = DocumentDBSetupConfiguration::default();
    let dbg = format!("{cfg:?}");
    assert!(
        dbg.contains("postgres_data_user_password: None"),
        "Debug output must show None when no password is set; got: {dbg}",
    );
    assert!(
        !dbg.contains("<redacted>"),
        "Debug output must not say <redacted> when no password is set; got: {dbg}",
    );
}

#[test]
#[cfg(unix)]
fn apply_pg_url_file_warns_on_world_readable() {
    // World-readable URL file should be accepted (warn) — not
    // refused, because read-only filesystems and special mounts
    // cannot always honor 0640.
    use std::os::unix::fs::PermissionsExt;
    let tmp = TempPath::with_content(
        b"postgresql://documentdb-gateway@/postgres?host=/run/test&port=9718",
    );
    std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o644)).unwrap();
    let mut cfg = DocumentDBSetupConfiguration::default();
    // Should succeed (warning is best-effort, not a hard failure).
    apply_pg_url_file(&mut cfg, tmp.path()).unwrap();
    assert_eq!(cfg.postgres_port, Some(9718));
}

#[test]
#[cfg(unix)]
fn apply_pg_url_file_silent_on_0600() {
    // The documented 0640 (or stricter 0600) should produce no
    // warning. We cannot capture tracing output directly here, but
    // we can verify the call succeeds without panic and the URL
    // is loaded as expected — the only behavioral signal we have.
    use std::os::unix::fs::PermissionsExt;
    let tmp = TempPath::with_content(
        b"postgresql://documentdb-gateway@/postgres?host=/run/test&port=9700",
    );
    std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut cfg = DocumentDBSetupConfiguration::default();
    apply_pg_url_file(&mut cfg, tmp.path()).unwrap();
    assert_eq!(cfg.postgres_port, Some(9700));
}

#[test]
#[cfg(unix)]
fn apply_pg_url_file_warns_on_group_writable() {
    // 0620 = owner RW, group W only. Caught by the
    // `mode & 0o020 != 0` branch in warn_if_url_file_too_permissive.
    use std::os::unix::fs::PermissionsExt;
    let tmp = TempPath::with_content(
        b"postgresql://documentdb-gateway@/postgres?host=/run/test&port=9620",
    );
    std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o620)).unwrap();
    let mut cfg = DocumentDBSetupConfiguration::default();
    apply_pg_url_file(&mut cfg, tmp.path()).unwrap();
    assert_eq!(cfg.postgres_port, Some(9620));
}

#[test]
fn split_host_port_bare_host() {
    let (host, port) = split_host_port("dbhost").unwrap();
    assert_eq!(host, "dbhost");
    assert_eq!(port, None);
}

#[test]
fn split_host_port_host_and_port() {
    let (host, port) = split_host_port("dbhost:5432").unwrap();
    assert_eq!(host, "dbhost");
    assert_eq!(port, Some("5432"));
}

#[test]
fn split_host_port_ipv6_no_port() {
    let (host, port) = split_host_port("[::1]").unwrap();
    assert_eq!(host, "::1");
    assert_eq!(port, None);
}

#[test]
fn split_host_port_ipv6_with_port() {
    let (host, port) = split_host_port("[2001:db8::1]:5432").unwrap();
    assert_eq!(host, "2001:db8::1");
    assert_eq!(port, Some("5432"));
}

#[test]
fn split_host_port_rejects_unterminated_bracket() {
    let err = split_host_port("[::1").unwrap_err();
    assert!(format!("{err:?}").contains("Unterminated"));
}

#[test]
fn split_host_port_rejects_extra_content_after_bracket() {
    let err = split_host_port("[::1]extra").unwrap_err();
    assert!(format!("{err:?}").contains("Unexpected content after ']'"));
}

#[test]
fn split_host_port_unix_socket_path() {
    // libpq's percent-decoded socket path form: leading slash, no
    // colon, no brackets. The rfind-on-colon branch handles it.
    let (host, port) = split_host_port("/var/run/postgresql").unwrap();
    assert_eq!(host, "/var/run/postgresql");
    assert_eq!(port, None);
}

#[test]
fn listen_addr_rejects_explicit_non_loopback_host() {
    // PR-Assistant security finding (Iter1): the listener
    // configuration only carries `use_local_host: bool`, so an
    // explicit non-loopback bind address like 192.0.2.10 was
    // previously silently downgraded to "all interfaces" — a
    // strictly broader exposure than the operator asked for.
    // The overlay must refuse it with a clear actionable error.
    let mut cfg = DocumentDBSetupConfiguration::default();
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, "192.0.2.10:10260"),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::PG_URL_FILE, ""),
    ]);
    let err = DocumentDBSetupConfiguration::apply_env_overlays(&mut cfg).unwrap_err();
    let msg = format!("{err:?}");
    assert!(
        msg.contains("192.0.2.10"),
        "error must name the rejected host; got: {msg}"
    );
    assert!(
        msg.contains("loopback") || msg.contains("all interfaces"),
        "error must direct operator to supported forms; got: {msg}"
    );
}

#[test]
fn listen_addr_accepts_loopback_explicit_hosts() {
    for host_form in ["127.0.0.1:10260", "localhost:10260", "[::1]:10260"] {
        let mut cfg = DocumentDBSetupConfiguration::default();
        let _guard = crate::testing::EnvGuard::set_many([
            (env_keys::LISTEN_ADDR, host_form),
            (env_keys::TLS_AUTO_GENERATE, ""),
            (env_keys::TLS_CERT_FILE, ""),
            (env_keys::TLS_KEY_FILE, ""),
            (env_keys::PG_URL_FILE, ""),
        ]);
        DocumentDBSetupConfiguration::apply_env_overlays(&mut cfg)
            .unwrap_or_else(|e| panic!("loopback form {host_form} should be accepted: {e:?}"));
        assert_eq!(cfg.use_local_host, Some(true), "for {host_form}");
        assert_eq!(cfg.gateway_listen_port, Some(10260), "for {host_form}");
    }
}

#[test]
fn listen_addr_accepts_bare_port_for_all_interfaces() {
    let mut cfg = DocumentDBSetupConfiguration::default();
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, ":10260"),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::PG_URL_FILE, ""),
    ]);
    DocumentDBSetupConfiguration::apply_env_overlays(&mut cfg).unwrap();
    assert_eq!(cfg.use_local_host, Some(false));
    assert_eq!(cfg.gateway_listen_port, Some(10260));
}

#[test]
fn env_only_populates_default_user_when_struct_default_left_them_empty() {
    // PR-Assistant reliability finding (Iter1): #[serde(default = "default_user")]
    // only fires during JSON deserialization, so the env-only path
    // (Self::default()) leaves postgres_system_user and
    // postgres_data_user as "". Without the defensive fill-in
    // from_env_with_optional_json adds, the gateway would pass
    // an empty user to the PG connection pool.
    let cfg = DocumentDBSetupConfiguration::default();
    assert_eq!(cfg.postgres_system_user, "", "Self::default leaves empty");
    assert_eq!(cfg.postgres_data_user, "", "Self::default leaves empty");

    // Exercise the env-only branch (no JSON path). We don't need
    // any env vars set — we just verify the user fields end up
    // non-empty after the loader runs.
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        ("PGPASSWORD", ""),
    ]);
    let loaded = DocumentDBSetupConfiguration::from_env_with_optional_json(None).unwrap();
    assert!(
        !loaded.postgres_system_user.is_empty(),
        "env-only load must populate postgres_system_user (got empty)"
    );
    assert!(
        !loaded.postgres_data_user.is_empty(),
        "env-only load must populate postgres_data_user (got empty)"
    );
}

#[test]
fn from_env_with_optional_json_errors_on_missing_explicit_path() {
    // PR-Assistant security finding (Iter5): silently treating
    // Some(missing) as None masks mis-typed paths. The lib
    // function must error so non-main callers (tests, embedded
    // variants) get a loud failure.
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        ("PGPASSWORD", ""),
    ]);
    let nonexistent = std::path::PathBuf::from("/this/path/does/not/exist/SetupConfiguration.json");
    let err =
        DocumentDBSetupConfiguration::from_env_with_optional_json(Some(&nonexistent)).unwrap_err();
    let msg = format!("{err:?}");
    assert!(
        msg.contains("does not exist"),
        "error must explain the missing path; got: {msg}"
    );
}

#[test]
fn from_env_with_optional_json_accepts_none_for_env_only_load() {
    // Companion to the above: `None` is the documented "env-only"
    // mode and must succeed without a file.
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        ("PGPASSWORD", ""),
    ]);
    DocumentDBSetupConfiguration::from_env_with_optional_json(None)
        .expect("None must load successfully (env-only mode)");
}

#[test]
fn tls_overlay_pem_file_requires_both_paths() {
    let mut opts = CertificateOptions::default();
    let err = apply_tls_overlay(&mut opts, Some("cert".into()), None, None).unwrap_err();
    assert!(format!("{err:?}").contains("DOCUMENTDB_TLS_KEY_FILE"));
}

#[test]
fn tls_overlay_auto_generate_clears_paths() {
    let mut opts = CertificateOptions {
        cert_type: CertInputType::PemFile,
        file_path: Some("/old/cert".into()),
        key_file_path: Some("/old/key".into()),
        ca_path: None,
    };
    apply_tls_overlay(&mut opts, None, None, Some(true)).unwrap();
    assert_eq!(opts.cert_type, CertInputType::PemAutoGenerated);
    assert!(opts.file_path.is_none());
    assert!(opts.key_file_path.is_none());
}

#[test]
fn tls_overlay_rejects_conflicting_auto_generate_and_files() {
    let mut opts = CertificateOptions::default();
    let err = apply_tls_overlay(
        &mut opts,
        Some("cert".into()),
        Some("key".into()),
        Some(true),
    )
    .unwrap_err();
    assert!(format!("{err:?}").contains("conflicts"));
}

#[test]
fn env_only_with_no_tls_settings_defaults_to_auto_generate() {
    // Per the packaging design: when no TLS cert/key paths are
    // supplied AND the operator has not set
    // DOCUMENTDB_TLS_AUTO_GENERATE explicitly, the documented
    // default is auto-generated self-signed certs. Without this
    // pass the env-only install (no JSON, no TLS env vars) leaves
    // certificate_options at CertInputType::PemFile with both file
    // paths None — TlsProvider::new then fails at startup. The
    // env-overlay pass must switch to PemAutoGenerated when
    // nothing was supplied.
    let mut cfg = DocumentDBSetupConfiguration::default();
    // Sanity: default is the broken pre-fix state.
    assert_eq!(cfg.certificate_options.cert_type, CertInputType::PemFile);
    assert!(cfg.certificate_options.file_path.is_none());
    assert!(cfg.certificate_options.key_file_path.is_none());

    // Use the shared EnvGuard to synchronize with other env-mutating
    // tests in the same process and to restore prior values on drop.
    // Setting empty strings unsets these for the purpose of the
    // overlay code: `read_env` treats trimmed-empty as None.
    // `apply_env_overlays` does not look at PGPASSWORD (that guard
    // runs only via `from_env_with_optional_json`), so we don't
    // need to clear it here.
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        (env_keys::LISTEN_ADDR, ""),
    ]);

    DocumentDBSetupConfiguration::apply_env_overlays(&mut cfg).unwrap();
    assert_eq!(
        cfg.certificate_options.cert_type,
        CertInputType::PemAutoGenerated,
        "env-only default must be auto-generated TLS",
    );
    assert!(cfg.certificate_options.file_path.is_none());
    assert!(cfg.certificate_options.key_file_path.is_none());
}

#[test]
fn env_overlay_with_cert_paths_keeps_pem_file_mode() {
    // Regression: the auto-generate default must NOT clobber a
    // valid PemFile config produced by overlaying env paths.
    let mut cfg = DocumentDBSetupConfiguration::default();
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::TLS_CERT_FILE, "/tmp/test-cert.pem"),
        (env_keys::TLS_KEY_FILE, "/tmp/test-key.pem"),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        (env_keys::LISTEN_ADDR, ""),
    ]);
    DocumentDBSetupConfiguration::apply_env_overlays(&mut cfg).unwrap();
    assert_eq!(cfg.certificate_options.cert_type, CertInputType::PemFile);
    assert_eq!(
        cfg.certificate_options.file_path.as_deref(),
        Some("/tmp/test-cert.pem"),
    );
    assert_eq!(
        cfg.certificate_options.key_file_path.as_deref(),
        Some("/tmp/test-key.pem"),
    );
}

#[test]
fn apply_pg_url_file_reads_and_decomposes_url() {
    let tmp = TempPath::with_content(b"postgresql://documentdb-gateway@/postgres?host=/run/documentdb-local/18/postgresql&port=9718\n");
    let mut cfg = DocumentDBSetupConfiguration::default();
    apply_pg_url_file(&mut cfg, tmp.path()).unwrap();
    assert_eq!(cfg.postgres_port, Some(9718));
    assert_eq!(cfg.postgres_database.as_deref(), Some("postgres"));
    assert_eq!(cfg.postgres_data_user, "documentdb-gateway");
    // The PG socket directory goes into postgres_host_name (for the
    // PG connection), NOT into unix_socket_path (which is the
    // gateway's own client-facing listener socket).
    assert_eq!(
        cfg.postgres_host_name.as_deref(),
        Some("/run/documentdb-local/18/postgresql")
    );
    assert_eq!(cfg.unix_socket_path, None);
}

#[test]
fn apply_pg_url_file_rejects_password() {
    let tmp = TempPath::with_content(b"postgresql://alice:secret@dbhost:5432/mydb\n");
    let mut cfg = DocumentDBSetupConfiguration::default();
    let err = apply_pg_url_file(&mut cfg, tmp.path()).unwrap_err();
    assert!(format!("{err:?}").contains("Password-bearing"));
}

#[test]
fn read_env_bool_accepts_synonyms() {
    // Use EnvGuard so this test serializes with every other env-mutating
    // test in the file. Raw `env::set_var` from a parallel test is UB on
    // most libcs (setenv/getenv are not thread-safe) even when the key is
    // "unique" — the C runtime's internal environ table is global state.
    let key = "DOCUMENTDB_TEST_BOOL_OK";
    {
        let _guard = crate::testing::EnvGuard::set_many([(key, "yes")]);
        assert_eq!(read_env_bool(key).unwrap(), Some(true));
    }
    {
        let _guard = crate::testing::EnvGuard::set_many([(key, "OFF")]);
        assert_eq!(read_env_bool(key).unwrap(), Some(false));
    }
    {
        // EnvGuard::set_many with "" leaves env::var returning Some(""),
        // which read_env_bool's empty-string handling treats as absent.
        let _guard = crate::testing::EnvGuard::set_many([(key, "")]);
        assert_eq!(read_env_bool(key).unwrap(), None);
    }
}

#[test]
fn read_env_bool_rejects_garbage() {
    // Use EnvGuard for the same UB-avoidance reason as above.
    let key = "DOCUMENTDB_TEST_BOOL_BAD";
    let _guard = crate::testing::EnvGuard::set_many([(key, "perhaps")]);
    let err = read_env_bool(key).unwrap_err();
    assert!(format!("{err:?}").contains("boolean"));
}

#[test]
fn from_env_with_optional_json_overlays_env_on_top_of_json() {
    // The headline scenario for Track 1: a packaged install ships a
    // baseline SetupConfiguration.json, the systemd unit also exports
    // DOCUMENTDB_* env vars, and the env values must win for fields the
    // operator explicitly overrode while JSON-only fields are preserved.
    // Without this test the overlay direction can silently invert (env
    // ignored, JSON wins) and the env-overlay feature becomes a no-op.
    let tmp = TempPath::with_content(
        b"{\"NodeHostName\":\"json-host\",\"BlockedRolePrefixes\":[],\"CertificateOptions\":{\"CertType\":\"PemAutoGenerated\"},\"GatewayListenPort\":5432}",
    );
    let _guard = crate::testing::EnvGuard::set_many([
        // Env overrides the listen port the JSON baseline set.
        (env_keys::LISTEN_ADDR, ":10260"),
        // Everything else explicitly cleared so we exercise only the
        // overlay direction we care about.
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        ("PGPASSWORD", ""),
    ]);
    let loaded = DocumentDBSetupConfiguration::from_env_with_optional_json(Some(tmp.path()))
        .expect("JSON+env load must succeed");
    // Env wins on the overlaid field.
    assert_eq!(
        loaded.gateway_listen_port,
        Some(10260),
        "DOCUMENTDB_LISTEN_ADDR=:10260 must override JSON's GatewayListenPort=5432"
    );
    // JSON-only fields are preserved.
    assert_eq!(
        loaded.node_host_name, "json-host",
        "node_host_name from JSON must survive when no env overrides it"
    );
}

#[test]
fn from_env_with_optional_json_rejects_non_empty_pgpassword() {
    // Security-critical positive test for reject_password_environment.
    // The existing tests all set PGPASSWORD="" (which is treated as
    // absent per libpq semantics); this is the first test that
    // verifies a real password value actually triggers the guard.
    // Without it, an accidental `if v.is_empty()` -> `if !v.is_empty()`
    // flip would silently disable the rejection path.
    let _guard = crate::testing::EnvGuard::set_many([
        (env_keys::LISTEN_ADDR, ""),
        (env_keys::TLS_CERT_FILE, ""),
        (env_keys::TLS_KEY_FILE, ""),
        (env_keys::TLS_AUTO_GENERATE, ""),
        (env_keys::PG_URL_FILE, ""),
        ("PGPASSWORD", "hunter2"),
    ]);
    let err = DocumentDBSetupConfiguration::from_env_with_optional_json(None)
        .expect_err("non-empty PGPASSWORD must be rejected");
    let msg = format!("{err:?}");
    assert!(
        msg.contains("PGPASSWORD"),
        "error must call out PGPASSWORD by name so operators know what to unset; got: {msg}"
    );
}
