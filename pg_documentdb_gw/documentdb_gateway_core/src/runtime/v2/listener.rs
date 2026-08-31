/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/listener.rs
 *
 *-------------------------------------------------------------------------
 */

//! Owns gateway listener startup, transport metadata, TLS, and task supervision.

use std::{net::IpAddr, pin::Pin, time::Duration};

use nacelle::core::{NacelleConnectionMeta, NacelleConnectionTlsMeta, TrackedPermit};
use openssl::ssl::Ssl;
use tokio::{
    net::{TcpStream, UnixListener, UnixStream},
    task::JoinSet,
};
use tokio_openssl::SslStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::ServiceContext,
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    runtime::v2::{connection::GatewayRuntime, wire},
    service::{create_tcp_listeners, ListenerConfig},
    telemetry::{record_startup_metrics, TelemetryProvider},
    time::STARTUP_INSTANT,
};

const TCP_KEEPALIVE_TIME_SECS: u64 = 180;
const TCP_KEEPALIVE_INTERVAL_SECS: u64 = 60;
const TLS_PEEK_TIMEOUT_SECS: u64 = 5;
const TLS_HANDSHAKE_TIMEOUT_SECS: u64 = 10;
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(30);

fn apply_tcp_options(tcp_stream: &TcpStream) -> std::io::Result<()> {
    tcp_stream.set_nodelay(true)?;
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(TCP_KEEPALIVE_TIME_SECS))
        .with_interval(Duration::from_secs(TCP_KEEPALIVE_INTERVAL_SECS));
    socket2::SockRef::from(tcp_stream).set_tcp_keepalive(&keepalive)
}

/// Detects whether a TCP stream begins with a TLS handshake record.
///
/// # Errors
///
/// Returns an error if peeking at the stream fails, times out, or reaches EOF.
pub(super) async fn detect_tls_handshake(
    tcp_stream: &TcpStream,
    connection_id: Uuid,
) -> Result<bool> {
    let mut peek_buffer = [0_u8; 3];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(TLS_PEEK_TIMEOUT_SECS);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(remaining, tcp_stream.peek(&mut peek_buffer)).await {
            Ok(Ok(0)) => {
                return Err(DocumentDBError::internal_error(
                    "Connection closed".to_owned(),
                ));
            }
            Ok(Ok(len)) => {
                if peek_buffer[0] != 0x16
                    || (len >= 2 && peek_buffer[1] != 0x03)
                    || (len >= 3 && !(0x01..=0x04).contains(&peek_buffer[2]))
                {
                    return Ok(false);
                }
                if len >= 3 {
                    return Ok(true);
                }
            }
            Ok(Err(error)) => {
                tracing::warn!(
                    activity_id = connection_id.to_string().as_str(),
                    "Error during TLS detection: {error:?}"
                );
                return Err(error.into());
            }
            Err(_) => {
                tracing::warn!(
                    activity_id = connection_id.to_string().as_str(),
                    "TLS detection peek operation timed out after {TLS_PEEK_TIMEOUT_SECS} seconds."
                );
                return Err(DocumentDBError::internal_error(
                    "Timeout reading from stream".to_owned(),
                ));
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn openssl_tls_meta(ssl: &openssl::ssl::SslRef) -> NacelleConnectionTlsMeta {
    let mut metadata = NacelleConnectionTlsMeta::new("openssl").with_protocol(ssl.version_str());
    if let Some(cipher) = ssl.current_cipher() {
        metadata = metadata.with_cipher_suite(cipher.name());
    }
    metadata
}

async fn serve_tcp_connection<T>(
    runtime: GatewayRuntime<T>,
    tcp_stream: TcpStream,
    peer_address: std::net::SocketAddr,
    listener: &'static str,
    _connection_permit: TrackedPermit,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    let connection_id = Uuid::new_v4();
    let connection_activity_id = connection_id.to_string();
    apply_tcp_options(&tcp_stream)?;
    let local_address = tcp_stream.local_addr().ok();
    let use_tls = runtime
        .service_context()
        .setup_configuration()
        .enforce_tls()
        || detect_tls_handshake(&tcp_stream, connection_id).await?;
    let connection =
        NacelleConnectionMeta::tcp(Some(peer_address), local_address).with_listener(listener);
    let ip_address = match peer_address.ip() {
        IpAddr::V6(ipv6) => ipv6.to_ipv4_mapped().map_or(IpAddr::V6(ipv6), IpAddr::V4),
        ip_address @ IpAddr::V4(_) => ip_address,
    };
    tracing::debug!(
        activity_id = connection_activity_id.as_str(),
        "Accepted new TCP connection - Connection Id {connection_id}, client IP {}",
        ip_address
    );

    if use_tls {
        let acceptor = runtime.service_context().tls_provider().tls_acceptor();
        let ssl = Ssl::new(acceptor.context())?;
        let mut tls_stream = SslStream::new(ssl, tcp_stream)?;
        tokio::time::timeout(
            Duration::from_secs(TLS_HANDSHAKE_TIMEOUT_SECS),
            SslStream::accept(Pin::new(&mut tls_stream)),
        )
        .await
        .map_err(|_elapsed| {
            tracing::error!(
                activity_id = connection_activity_id.as_str(),
                "Failed to create TLS connection: SSL handshake timed out. - Connection Id {connection_id}, client IP {ip_address}"
            );
            DocumentDBError::internal_error("SSL handshake timed out.".to_owned())
        })?
        .map_err(|error| {
            tracing::error!(
                activity_id = connection_activity_id.as_str(),
                "Failed to create TLS connection: {error:?}. - Connection Id {connection_id}, client IP {ip_address}"
            );
            DocumentDBError::internal_error(format!("SSL handshake failed: {error:?}."))
        })?;
        let connection = connection.with_tls(openssl_tls_meta(tls_stream.ssl()));
        tracing::info!(
            activity_id = connection_activity_id.as_str(),
            "TLS TCP connection established - Connection Id {connection_id}, client IP {}",
            ip_address
        );
        runtime
            .serve(tls_stream, connection, connection_id)
            .await
            .map_err(|error| wire::error_to_documentdb(&error))?;
    } else {
        tracing::info!(
            activity_id = connection_activity_id.as_str(),
            "Non-TLS TCP connection established - Connection Id {connection_id}, client IP {}",
            ip_address
        );
        runtime
            .serve(tcp_stream, connection, connection_id)
            .await
            .map_err(|error| wire::error_to_documentdb(&error))?;
    }

    tracing::debug!(
        activity_id = connection_activity_id.as_str(),
        "Connection closed."
    );
    Ok(())
}

/// Creates a Unix socket listener with the requested filesystem permissions.
///
/// # Errors
///
/// Returns an error if the listener cannot bind or its permissions cannot be set.
pub(super) fn create_unix_socket_listener(path: &str, permissions: u32) -> Result<UnixListener> {
    use std::os::unix::fs::PermissionsExt;

    if let Err(error) = std::fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!("Could not remove existing socket file {path}: {error}.");
        }
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(permissions))?;
    tracing::info!("Unix socket listener bound to {path} with permissions {permissions:o}");
    Ok(listener)
}

async fn serve_unix_connection<T>(
    runtime: GatewayRuntime<T>,
    unix_stream: UnixStream,
    path: String,
    _connection_permit: TrackedPermit,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    let connection_id = Uuid::new_v4();
    let connection_activity_id = connection_id.to_string();
    tracing::debug!(
        activity_id = connection_activity_id.as_str(),
        "New Unix socket connection established"
    );
    let connection =
        NacelleConnectionMeta::unix_socket(Some(path.into())).with_listener("gateway-unix");
    tracing::info!(
        activity_id = connection_activity_id.as_str(),
        "Unix socket connection established - Connection Id {connection_id}"
    );
    runtime
        .serve(unix_stream, connection, connection_id)
        .await
        .map_err(|error| wire::error_to_documentdb(&error))?;
    tracing::debug!(
        activity_id = connection_activity_id.as_str(),
        "Connection closed."
    );
    Ok(())
}

fn spawn_tcp_connection<T>(
    tasks: &mut JoinSet<Result<()>>,
    runtime: &GatewayRuntime<T>,
    stream: TcpStream,
    peer: std::net::SocketAddr,
    listener: &'static str,
) where
    T: PgDataClient + 'static,
{
    match runtime.acquire_connection(Some(peer.ip())) {
        Ok(permit) => {
            tasks.spawn(serve_tcp_connection(
                runtime.clone(),
                stream,
                peer,
                listener,
                permit,
            ));
        }
        Err(error) => runtime.record_connection_rejection("tcp", &error),
    }
}

fn log_connection_result(result: std::result::Result<Result<()>, tokio::task::JoinError>) {
    match result {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::error!("Gateway runtime connection failed: {error:?}."),
        Err(error) => tracing::error!("Gateway runtime connection task failed: {error:?}."),
    }
}

/// Reaps every connection task that has already completed.
pub(super) fn drain_completed_connections(tasks: &mut JoinSet<Result<()>>) {
    while let Some(result) = tasks.try_join_next() {
        log_connection_result(result);
    }
}

async fn drain_connections(tasks: &mut JoinSet<Result<()>>) {
    let deadline = tokio::time::Instant::now() + SHUTDOWN_DRAIN_TIMEOUT;
    while !tasks.is_empty() {
        tokio::select! {
            result = tasks.join_next() => {
                if let Some(result) = result {
                    log_connection_result(result);
                }
            }
            () = tokio::time::sleep_until(deadline) => {
                tasks.abort_all();
                while let Some(result) = tasks.join_next().await {
                    log_connection_result(result);
                }
                break;
            }
        }
    }
}

fn record_startup(elapsed: Duration, telemetry: Option<&dyn TelemetryProvider>) {
    tracing::info!(
        startup_duration_ms = elapsed.as_millis(),
        "Gateway ready to accept connections."
    );

    match telemetry {
        Some(provider) => provider.record_startup_duration(elapsed),
        None => record_startup_metrics(elapsed),
    }
}

/// Runs the gateway runtime.
///
/// # Errors
///
/// Returns an error if the runtime fails to bind, serve, or shut down its configured
/// listeners.
pub async fn run_gateway<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    token: CancellationToken,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    let listener_config = ListenerConfig::from(service_context.setup_configuration());
    let (ipv4_listener, ipv6_listener) = create_tcp_listeners(&listener_config).await?;
    tracing::info!("TCP listener(s) bound to port {}", listener_config.port());
    let unix_socket_path = listener_config.unix_socket_path().map(ToOwned::to_owned);
    let unix_listener = if let Some(path) = unix_socket_path.as_deref() {
        Some(create_unix_socket_listener(
            path,
            listener_config.unix_socket_permissions(),
        )?)
    } else {
        tracing::info!("Unix socket disabled (not configured)");
        None
    };
    record_startup(
        STARTUP_INSTANT
            .get_or_init(tokio::time::Instant::now)
            .elapsed(),
        telemetry.as_deref(),
    );
    let runtime = GatewayRuntime::<T>::new(service_context, telemetry, token.clone());
    let mut connections = JoinSet::new();

    loop {
        drain_completed_connections(&mut connections);
        tokio::select! {
            result = async {
                match &ipv4_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv4_listener.is_some() => {
                match result {
                    Ok((stream, peer)) => {
                        spawn_tcp_connection(
                            &mut connections, &runtime, stream, peer, "gateway-ipv4",
                        );
                    }
                    Err(error) => tracing::error!("Failed to accept a TCP connection (IPv4): {error:?}."),
                }
            }
            result = async {
                match &ipv6_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv6_listener.is_some() => {
                match result {
                    Ok((stream, peer)) => {
                        spawn_tcp_connection(
                            &mut connections, &runtime, stream, peer, "gateway-ipv6",
                        );
                    }
                    Err(error) => tracing::error!("Failed to accept a TCP connection (IPv6): {error:?}."),
                }
            }
            result = async {
                match &unix_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if unix_listener.is_some() => {
                match result {
                    Ok((stream, _)) => {
                        match runtime.acquire_connection(None) {
                            Ok(permit) => {
                                let path = unix_socket_path.clone().unwrap_or_default();
                                connections.spawn(serve_unix_connection(
                                    runtime.clone(), stream, path, permit,
                                ));
                            }
                            Err(error) => {
                                runtime.record_connection_rejection("unix_socket", &error);
                            }
                        }
                    }
                    Err(error) => tracing::error!("Failed to accept a Unix socket connection: {error:?}."),
                }
            }
            result = connections.join_next(), if !connections.is_empty() => {
                if let Some(result) = result {
                    log_connection_result(result);
                }
            }
            () = token.cancelled() => break,
        }
    }

    drop(ipv4_listener);
    drop(ipv6_listener);
    drop(unix_listener);
    drain_connections(&mut connections).await;
    Ok(())
}
