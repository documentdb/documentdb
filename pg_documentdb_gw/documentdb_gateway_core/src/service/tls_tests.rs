/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/tls_tests.rs
 *
 * Test module for tls.rs. Pulled into tls.rs via:
 *   #[cfg(test)] #[path = "tls_tests.rs"] mod tests;
 * so the test module is still a child of `tls` and reaches the state-dir
 * helpers via `super::state_dir::*` with zero visibility changes.
 *-------------------------------------------------------------------------
 */

use std::pin::Pin;

use openssl::{
    asn1::Asn1Time,
    hash::MessageDigest,
    pkey::PKey,
    rsa::Rsa,
    ssl::{
        Ssl, SslAcceptor, SslConnector, SslMethod, SslSession, SslSessionRef, SslVerifyMode,
        SslVersion,
    },
    x509::{X509Builder, X509NameBuilder},
};
use tokio::io::AsyncWriteExt;
use tokio_openssl::SslStream;

use super::{
    state_dir::{
        resolve_tls_state_dir, tls_paths_for_dir, try_ensure_dir, user_local_state_dir,
        DEFAULT_TLS_STATE_DIR, ENV_TLS_STATE_DIR,
    },
    CertificateBundle, TlsProvider,
};
use crate::service::docdb_openssl::create_tls_acceptor;

#[test]
fn tls_paths_for_dir_joins_with_conventional_filenames() {
    let (cert, key) = tls_paths_for_dir("/var/lib/documentdb-gateway/tls");
    assert_eq!(cert, "/var/lib/documentdb-gateway/tls/cert.pem");
    assert_eq!(key, "/var/lib/documentdb-gateway/tls/pkey.pem");
}

#[test]
fn tls_paths_for_dir_handles_per_major_directory() {
    // Mirrors the value the per-major gateway-local@N.service sets
    // via Environment=DOCUMENTDB_TLS_STATE_DIR=...
    let (cert, key) = tls_paths_for_dir("/var/lib/documentdb-local/18/gateway/tls");
    assert_eq!(cert, "/var/lib/documentdb-local/18/gateway/tls/cert.pem");
    assert_eq!(key, "/var/lib/documentdb-local/18/gateway/tls/pkey.pem");
}

#[test]
fn default_tls_state_dir_is_absolute() {
    // Regression guard: this used to default to relative "./pkey.pem"
    // / "./cert.pem", which depended on whatever cwd the gateway
    // inherited and was both invisible to operators and unsafe
    // when --check was invoked from a non-writable directory.
    assert!(
        DEFAULT_TLS_STATE_DIR.starts_with('/'),
        "DEFAULT_TLS_STATE_DIR must be absolute; got {DEFAULT_TLS_STATE_DIR}"
    );
}

#[test]
fn user_local_state_dir_prefers_xdg_when_set() {
    let _guard = crate::testing::EnvGuard::set_many([
        ("XDG_STATE_HOME", "/custom/xdg/state"),
        ("HOME", "/home/should-be-ignored"),
    ]);
    let dir = user_local_state_dir();
    assert_eq!(dir, "/custom/xdg/state/documentdb-gateway/tls");
}

#[test]
fn user_local_state_dir_falls_back_to_home_when_xdg_absent() {
    // EnvGuard::set_many with an empty string for XDG_STATE_HOME
    // makes `env::var` return Some("") which is then filtered out by
    // the `.filter(|s| !s.is_empty())` in user_local_state_dir.
    let _guard =
        crate::testing::EnvGuard::set_many([("XDG_STATE_HOME", ""), ("HOME", "/home/operator")]);
    let dir = user_local_state_dir();
    assert_eq!(dir, "/home/operator/.local/state/documentdb-gateway/tls");
}

#[test]
fn user_local_state_dir_falls_back_to_tempdir_when_both_absent() {
    let _guard = crate::testing::EnvGuard::set_many([("XDG_STATE_HOME", ""), ("HOME", "")]);
    let dir = user_local_state_dir();
    // We do not assert the exact path because std::env::temp_dir()
    // returns something OS-specific; assert that the path contains
    // our distinguishing suffix and is not an empty string.
    assert!(
        dir.contains("documentdb-gateway-tls"),
        "tempdir fallback must contain 'documentdb-gateway-tls'; got: {dir}"
    );
    assert!(!dir.is_empty());
}

#[test]
fn try_ensure_dir_creates_nested_path_with_0700() {
    let base = std::env::temp_dir().join(format!(
        "documentdb-gateway-try-ensure-{}",
        uuid::Uuid::new_v4()
    ));
    let nested = base.join("a/b/c");
    let nested_str = nested.to_string_lossy().into_owned();
    try_ensure_dir(&nested_str).expect("create_dir_all should succeed in tempdir");
    assert!(nested.exists(), "nested dir must exist");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&nested).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o700,
            "leaf dir should be chmod'd to 0700; got {mode:#o}"
        );
    }
    // Cleanup.
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn try_ensure_dir_returns_err_on_uncreatable_path() {
    // A path under a non-existent device cannot be created. The
    // exact error kind varies by OS, but `create_dir_all` returns
    // an Err — that's what we want to verify propagates.
    let result = try_ensure_dir("/proc/self/cmdline/not-a-dir");
    assert!(
        result.is_err(),
        "try_ensure_dir should propagate filesystem errors as Err"
    );
}

#[test]
fn resolve_tls_state_dir_honors_explicit_env_override() {
    let tempdir = std::env::temp_dir().join(format!(
        "documentdb-gateway-resolver-{}",
        uuid::Uuid::new_v4()
    ));
    let tempdir_str = tempdir.to_string_lossy().into_owned();
    let _guard = crate::testing::EnvGuard::set_many([(ENV_TLS_STATE_DIR, tempdir_str.as_str())]);
    let dir = resolve_tls_state_dir().expect("resolver should succeed for writable env path");
    assert_eq!(dir, tempdir_str);
    assert!(
        tempdir.exists(),
        "resolver must create the dir as a side effect"
    );
    // Cleanup.
    let _ = std::fs::remove_dir_all(&tempdir);
}

#[test]
fn resolve_tls_state_dir_propagates_error_from_uncreatable_env_override() {
    // Operator wins, including their mistakes — we surface the
    // error rather than silently picking another path.
    let _guard =
        crate::testing::EnvGuard::set_many([(ENV_TLS_STATE_DIR, "/proc/self/cmdline/not-a-dir")]);
    let result = resolve_tls_state_dir();
    assert!(
        result.is_err(),
        "explicit env override that can't be created must error, not silently fall back"
    );
}

/// Builds the gateway acceptor around a freshly generated self-signed certificate.
fn gateway_acceptor() -> SslAcceptor {
    let private_key =
        PKey::from_rsa(Rsa::generate(2048).expect("RSA key generation")).expect("private key wrap");
    let mut name = X509NameBuilder::new().expect("name builder");
    name.append_entry_by_text("CN", "localhost")
        .expect("CN entry");
    let name = name.build();

    let mut certificate = X509Builder::new().expect("certificate builder");
    certificate.set_version(2).expect("version");
    certificate.set_subject_name(&name).expect("subject");
    certificate.set_issuer_name(&name).expect("issuer");
    certificate.set_pubkey(&private_key).expect("public key");
    certificate
        .set_not_before(&Asn1Time::days_from_now(0).expect("not before"))
        .expect("set not before");
    certificate
        .set_not_after(&Asn1Time::days_from_now(1).expect("not after"))
        .expect("set not after");
    certificate
        .sign(&private_key, MessageDigest::sha256())
        .expect("sign");

    let bundle = CertificateBundle {
        certificate: certificate.build(),
        private_key,
        ca_chain: Vec::new(),
    };
    create_tls_acceptor(&bundle, None)
        .expect("gateway acceptor")
        .build()
}

fn test_connector(max_version: Option<SslVersion>) -> SslConnector {
    let mut connector = SslConnector::builder(SslMethod::tls_client()).expect("connector builder");
    connector.set_verify(SslVerifyMode::NONE);
    connector
        .set_max_proto_version(max_version)
        .expect("max protocol version");
    connector.build()
}

/// What the server observed for one completed handshake.
struct ObservedHandshake {
    logged_sni: String,
    session_reused: bool,
    client_session: SslSession,
}

/// Completes a TLS handshake over an in-memory pipe, optionally resuming
/// `resume_session`, and closes the connection cleanly so the session stays
/// resumable.
async fn handshake(
    acceptor: &SslAcceptor,
    connector: &SslConnector,
    client_sni: Option<&str>,
    resume_session: Option<&SslSessionRef>,
) -> ObservedHandshake {
    let mut client_config = connector.configure().expect("client configuration");
    client_config.set_use_server_name_indication(client_sni.is_some());
    client_config.set_verify_hostname(false);
    let mut client_ssl = client_config
        .into_ssl(client_sni.unwrap_or("unused"))
        .expect("client ssl");
    if let Some(session) = resume_session {
        // SAFETY: the session was produced by a handshake using this same
        // connector's context, which is the requirement of `set_session`.
        unsafe { client_ssl.set_session(session) }.expect("set client session");
    }

    let (client_io, server_io) = tokio::io::duplex(16 * 1024);
    let mut client_stream = SslStream::new(client_ssl, client_io).expect("client stream");
    let mut server_stream =
        SslStream::new(Ssl::new(acceptor.context()).expect("server ssl"), server_io)
            .expect("server stream");

    let (client_result, server_result) = tokio::join!(
        Pin::new(&mut client_stream).connect(),
        Pin::new(&mut server_stream).accept()
    );
    client_result.expect("client handshake");
    server_result.expect("server handshake");

    let observed = ObservedHandshake {
        logged_sni: TlsProvider::sni_host_name_for_logging(server_stream.ssl()).to_string(),
        session_reused: server_stream.ssl().session_reused(),
        client_session: client_stream
            .ssl()
            .session()
            .expect("client session")
            .to_owned(),
    };
    let _ = tokio::join!(client_stream.shutdown(), server_stream.shutdown());
    observed
}

#[tokio::test]
async fn sni_host_name_returns_host_sent_by_client() {
    let observed = handshake(
        &gateway_acceptor(),
        &test_connector(None),
        Some("cluster.example.com"),
        None,
    )
    .await;
    assert_eq!(observed.logged_sni, "cluster.example.com");
}

#[tokio::test]
async fn sni_host_name_is_empty_when_client_sends_none() {
    let observed = handshake(&gateway_acceptor(), &test_connector(None), None, None).await;
    assert_eq!(observed.logged_sni, "");
}

#[tokio::test]
async fn sni_host_name_escapes_control_characters() {
    let observed = handshake(
        &gateway_acceptor(),
        &test_connector(None),
        Some("evil\nforged\rline"),
        None,
    )
    .await;
    assert_eq!(observed.logged_sni, "evil\\nforged\\rline");
}

#[tokio::test]
async fn sni_host_name_survives_tls12_session_resumption() {
    let acceptor = gateway_acceptor();
    let connector = test_connector(Some(SslVersion::TLS1_2));
    let first = handshake(&acceptor, &connector, Some("cluster.example.com"), None).await;
    assert!(!first.session_reused);

    let resumed = handshake(
        &acceptor,
        &connector,
        Some("cluster.example.com"),
        Some(&first.client_session),
    )
    .await;
    assert!(resumed.session_reused, "the second handshake should resume");
    assert_eq!(resumed.logged_sni, "cluster.example.com");
}
