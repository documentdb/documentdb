/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/runtime/v1.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{net::IpAddr, pin::Pin, time::Duration};

use openssl::ssl::Ssl;
use tokio::{
    io::BufStream,
    net::{unix::SocketAddr as UnixSocketAddr, TcpStream, UnixListener, UnixStream},
    time::Instant,
};
use tokio_openssl::SslStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::{ConnectionContext, ServiceContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    service::{self, ListenerConfig},
    telemetry::{record_startup_metrics, TelemetryProvider},
    time::STARTUP_INSTANT,
};

const TCP_KEEPALIVE_TIME_SECS: u64 = 180;
const TCP_KEEPALIVE_INTERVAL_SECS: u64 = 60;
const TLS_PEEK_TIMEOUT_SECS: u64 = 5;

fn apply_tcp_options(tcp_stream: &TcpStream) -> std::io::Result<()> {
    tcp_stream.set_nodelay(true)?;

    let tcp_keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(TCP_KEEPALIVE_TIME_SECS))
        .with_interval(Duration::from_secs(TCP_KEEPALIVE_INTERVAL_SECS));
    socket2::SockRef::from(tcp_stream).set_tcp_keepalive(&tcp_keepalive)?;

    Ok(())
}

#[cfg(unix)]
fn apply_socket_permissions(path: &str, permissions: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let file_permissions = std::fs::Permissions::from_mode(permissions);
    std::fs::set_permissions(path, file_permissions)
}

#[cfg(not(unix))]
fn apply_socket_permissions(_path: &str, _permissions: u32) -> std::io::Result<()> {
    Ok(())
}

fn create_unix_socket_listener(socket_path: &str, permissions: u32) -> Result<UnixListener> {
    if let Err(error) = std::fs::remove_file(socket_path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!(
                "Could not remove existing socket file {}: {}.",
                socket_path,
                error
            );
        }
    }

    let listener = UnixListener::bind(socket_path)?;

    apply_socket_permissions(socket_path, permissions)?;

    tracing::info!(
        "Unix socket listener bound to {} with permissions {:o}",
        socket_path,
        permissions
    );
    Ok(listener)
}

/// Runs the `DocumentDB` gateway v1 runtime, binding listeners and accepting
/// connections until the cancellation token is triggered.
///
/// The startup duration is recorded via [`crate::time::STARTUP_INSTANT`] once
/// the listeners are bound and the gateway is ready to accept connections.
///
/// # Errors
///
/// Returns an error if listener binding fails or a fatal error occurs in the
/// accept loop.
pub async fn run_gateway<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    token: CancellationToken,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    let listener_config = ListenerConfig::from(service_context.setup_configuration());

    let (ipv4_listener, ipv6_listener) = service::create_tcp_listeners(&listener_config).await?;

    tracing::info!("TCP listener(s) bound to port {}", listener_config.port());

    let unix_listener = if let Some(unix_socket_path) = listener_config.unix_socket_path() {
        let permissions = listener_config.unix_socket_permissions();
        let unix_listener = create_unix_socket_listener(unix_socket_path, permissions)?;
        Some(unix_listener)
    } else {
        tracing::info!("Unix socket disabled (not configured)");
        None
    };

    // The listeners are bound, so the gateway is now ready to accept
    // connections. Record the startup duration through a single shared site.
    record_startup(
        STARTUP_INSTANT.get_or_init(Instant::now).elapsed(),
        telemetry.as_deref(),
    );

    loop {
        tokio::select! {
            result = async {
                match &ipv4_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv4_listener.is_some() => {
                spawn_tcp_handler::<T>(
                    result,
                    service_context.clone(),
                    telemetry.clone(),
                    "IPv4",
                );
            }
            result = async {
                match &ipv6_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv6_listener.is_some() => {
                spawn_tcp_handler::<T>(
                    result,
                    service_context.clone(),
                    telemetry.clone(),
                    "IPv6",
                );
            }
            result = async {
                match &unix_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if unix_listener.is_some() => {
                spawn_unix_handler::<T>(result, service_context.clone(), telemetry.clone());
            }
            () = token.cancelled() => {
                return Ok(())
            }
        }
    }
}

/// Records the gateway startup duration through the single shared call site.
///
/// Routes through the [`TelemetryProvider`] when one is supplied (so providers
/// like the Geneva provider can emit to their own sinks in addition to
/// `OpenTelemetry`); otherwise records the `OpenTelemetry` startup metrics
/// directly, matching the trait's default behavior.
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

fn spawn_tcp_handler<T>(
    stream_and_address: std::io::Result<(TcpStream, std::net::SocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    protocol: &'static str,
) where
    T: PgDataClient + 'static,
{
    tokio::spawn(async move {
        if let Err(error) =
            handle_connection::<T>(stream_and_address, service_context, telemetry).await
        {
            tracing::error!("Failed to accept a TCP connection ({protocol}): {error:?}.");
        }
    });
}

fn spawn_unix_handler<T>(
    stream_result: std::io::Result<(UnixStream, UnixSocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
) where
    T: PgDataClient + 'static,
{
    tokio::spawn(async move {
        if let Err(error) =
            handle_unix_connection::<T>(stream_result, service_context, telemetry).await
        {
            tracing::error!("Failed to accept a Unix socket connection: {error:?}.");
        }
    });
}

async fn detect_tls_handshake(tcp_stream: &TcpStream, connection_id: Uuid) -> Result<bool> {
    let mut peek_buf = [0u8; 3];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(TLS_PEEK_TIMEOUT_SECS);

    loop {
        let time_remaining = deadline.saturating_duration_since(tokio::time::Instant::now());

        match tokio::time::timeout(time_remaining, tcp_stream.peek(&mut peek_buf)).await {
            Ok(Ok(0)) => {
                return Err(DocumentDBError::internal_error(
                    "Connection closed".to_owned(),
                ));
            }
            Ok(Ok(n)) => {
                if peek_buf[0] != 0x16
                    || (n >= 2 && peek_buf[1] != 0x03)
                    || (n >= 3 && (peek_buf[2] < 0x01 || peek_buf[2] > 0x04))
                {
                    return Ok(false);
                }

                if n >= 3 {
                    return Ok(true);
                }
            }
            Ok(Err(error)) => {
                tracing::warn!(
                    activity_id = connection_id.to_string().as_str(),
                    "Error during TLS detection: {error:?}"
                );
                return Err(DocumentDBError::internal_error(format!(
                    "Error reading from stream {error:?}"
                )));
            }
            Err(_) => {
                tracing::warn!(
                    activity_id = connection_id.to_string().as_str(),
                    "TLS detection peek operation timed out after {} seconds.",
                    TLS_PEEK_TIMEOUT_SECS
                );
                return Err(DocumentDBError::internal_error(
                    "Timeout reading from stream".to_owned(),
                ));
            }
        }

        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn handle_connection<T>(
    stream_and_address: std::result::Result<(TcpStream, std::net::SocketAddr), std::io::Error>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    let (tcp_stream, peer_address) = stream_and_address?;

    let connection_id = Uuid::new_v4();
    tracing::info!(
        activity_id = connection_id.to_string().as_str(),
        "Accepted new TCP connection"
    );

    apply_tcp_options(&tcp_stream)?;

    let is_tls = if service_context.setup_configuration().enforce_tls() {
        true
    } else {
        detect_tls_handshake(&tcp_stream, connection_id).await?
    };

    let ip_address = match peer_address.ip() {
        IpAddr::V4(v4) => IpAddr::V4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                IpAddr::V4(v4)
            } else {
                IpAddr::V6(v6)
            }
        }
    };

    if is_tls {
        let tls_acceptor = service_context.tls_provider().tls_acceptor();
        let ssl_session = Ssl::new(tls_acceptor.context())?;
        let mut tls_stream = SslStream::new(ssl_session, tcp_stream)?;

        if let Err(ssl_error) = SslStream::accept(Pin::new(&mut tls_stream)).await {
            tracing::error!("Failed to create TLS connection: {ssl_error:?}.");
            return Err(DocumentDBError::internal_error(format!(
                "SSL handshake failed: {ssl_error:?}."
            )));
        }

        let connection_context = ConnectionContext::new(
            service_context,
            telemetry,
            ip_address.to_string(),
            Some(tls_stream.ssl()),
            connection_id,
            "TCP".to_owned(),
        );

        let setup_configuration = connection_context.service_context.setup_configuration();

        let buffered_stream = BufStream::with_capacity(
            setup_configuration.stream_read_buffer_size(),
            setup_configuration.stream_write_buffer_size(),
            tls_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        service::handle_stream::<T, _>(buffered_stream, connection_context).await;
    } else {
        let connection_context = ConnectionContext::new(
            service_context,
            telemetry,
            ip_address.to_string(),
            None,
            connection_id,
            "TCP".to_owned(),
        );

        let setup_configuration = connection_context.service_context.setup_configuration();

        let buffered_stream = BufStream::with_capacity(
            setup_configuration.stream_read_buffer_size(),
            setup_configuration.stream_write_buffer_size(),
            tcp_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "Non-TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        service::handle_stream::<T, _>(buffered_stream, connection_context).await;
    }

    Ok(())
}

async fn handle_unix_connection<T>(
    stream_result: std::result::Result<(UnixStream, UnixSocketAddr), std::io::Error>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
) -> Result<()>
where
    T: PgDataClient,
{
    let (unix_stream, _socket_addr) = stream_result?;

    let connection_id = Uuid::new_v4();
    tracing::info!(
        activity_id = connection_id.to_string().as_str(),
        "New Unix socket connection established"
    );

    let connection_context = ConnectionContext::new(
        service_context,
        telemetry,
        "localhost".to_owned(),
        None,
        connection_id,
        "UnixSocket".to_owned(),
    );

    let setup_configuration = connection_context.service_context.setup_configuration();

    let buffered_stream = BufStream::with_capacity(
        setup_configuration.stream_read_buffer_size(),
        setup_configuration.stream_write_buffer_size(),
        unix_stream,
    );

    tracing::info!(
        activity_id = connection_id.to_string().as_str(),
        "Unix socket connection established - Connection Id {connection_id}"
    );

    service::handle_stream::<T, _>(buffered_stream, connection_context).await;
    Ok(())
}
