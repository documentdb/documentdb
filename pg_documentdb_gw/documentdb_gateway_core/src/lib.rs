/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/lib.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod auth;
pub mod bson;
pub mod configuration;
pub mod context;
pub mod error;
pub mod explain;
pub mod postgres;
pub mod processor;
pub mod protocol;
pub mod requests;
pub mod responses;
pub mod service;
pub mod shutdown_controller;
pub mod startup;
pub mod telemetry;

#[cfg(test)]
pub(crate) mod testing;

use std::{net::IpAddr, pin::Pin};

use openssl::ssl::Ssl;
use socket2::TcpKeepalive;
use tokio::{
    io::BufStream,
    net::{unix::SocketAddr as UnixSocketAddr, TcpStream, UnixListener, UnixStream},
    time::Duration,
};
use tokio_openssl::SslStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::{ConnectionContext, ServiceContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    telemetry::TelemetryProvider,
};
// TCP keepalive configuration constants
const TCP_KEEPALIVE_TIME_SECS: u64 = 180;
const TCP_KEEPALIVE_INTERVAL_SECS: u64 = 60;

// TLS detection timeout
const TLS_PEEK_TIMEOUT_SECS: u64 = 5;

/// Applies configurable permissions to Unix domain socket file.
///
/// On Unix systems: Sets permissions to the specified octal value
/// On other platforms: No-op (permissions handled by OS defaults)
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

/// Creates and configures a Unix domain socket listener.
///
/// This function handles the complete Unix socket setup:
/// 1. Removes stale socket file from previous run (crash recovery)
/// 2. Binds to the socket path
/// 3. Sets appropriate permissions via platform-specific logic
///
/// # Arguments
///
/// * `socket_path` - Path where the Unix socket should be created
/// * `permissions` - Octal file permissions (e.g., 0o660)
///
/// # Returns
///
/// Returns the configured `UnixListener` or an error if setup fails.
///
/// # Errors
///
/// This function will return an error if:
/// * Failed to bind to the socket path
/// * Failed to set socket file permissions
fn create_unix_socket_listener(socket_path: &str, permissions: u32) -> Result<UnixListener> {
    // Attempt to remove stale socket file from previous run (e.g., after crash).
    // This is standard Unix socket practice - PostgreSQL, MySQL, Redis all use this pattern.
    // Socket files cannot be cleaned up during crash (SIGKILL, segfault, power loss, etc.),
    // so cleanup at startup is the only reliable approach for crash recovery.
    // If the file couldn't be removed, bind() will fail with clear error "Address already in use".
    if let Err(e) = std::fs::remove_file(socket_path) {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!(
                "Could not remove existing socket file {}: {}.",
                socket_path,
                e
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

/// Runs the `DocumentDB` gateway server, accepting and handling incoming connections.
///
/// This function sets up a TCP listener and SSL context, then continuously accepts
/// new connections until the cancellation token is triggered. Each connection is
/// handled in a separate async task.
///
/// # Arguments
///
/// * `service_context` - The service configuration and context
/// * `telemetry` - Optional telemetry provider for metrics and logging
/// * `token` - Cancellation token to gracefully shutdown the gateway
///
/// # Returns
///
/// Returns `Ok(())` on successful shutdown, or an error if the server fails to start
/// or encounters a fatal error during operation.
///
/// # Errors
///
/// This function will return an error if:
/// * Failed to bind to the specified address and port
/// * SSL context creation fails
/// * Any other fatal gateway initialization error occurs
pub async fn run_gateway<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    token: CancellationToken,
) -> Result<()>
where
    T: PgDataClient,
{
    let (ipv4_listener, ipv6_listener) = service::create_tcp_listeners(
        service_context.setup_configuration().use_local_host(),
        service_context.setup_configuration().gateway_listen_port(),
    )
    .await?;

    tracing::info!(
        "TCP listener(s) bound to port {}",
        service_context.setup_configuration().gateway_listen_port()
    );

    let unix_listener =
        if let Some(unix_socket_path) = service_context.setup_configuration().unix_socket_path() {
            let permissions = service_context
                .setup_configuration()
                .unix_socket_file_permissions();
            let unix_listener = create_unix_socket_listener(unix_socket_path, permissions)?;
            Some(unix_listener)
        } else {
            tracing::info!("Unix socket disabled (not configured)");
            None
        };

    // Listen for new tcp and unix socket connections
    loop {
        tokio::select! {
            // Handle IPv4 TCP connections
            result = async {
                match &ipv4_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv4_listener.is_some() => {
                spawn_tcp_handler::<T>(result, service_context.clone(), telemetry.clone(), "IPv4");
            }
            // Handle IPv6 TCP connections
            result = async {
                match &ipv6_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv6_listener.is_some() => {
                spawn_tcp_handler::<T>(result, service_context.clone(), telemetry.clone(), "IPv6");
            }
            // Handle Unix socket connections
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

/// Spawns an async task to handle a TCP connection.
fn spawn_tcp_handler<T>(
    stream_and_address: std::io::Result<(TcpStream, std::net::SocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    protocol: &'static str,
) where
    T: PgDataClient,
{
    tokio::spawn(async move {
        if let Err(err) =
            handle_connection::<T>(stream_and_address, service_context, telemetry).await
        {
            tracing::error!("Failed to accept a TCP connection ({protocol}): {err:?}.");
        }
    });
}

/// Spawns an async task to handle a Unix socket connection.
fn spawn_unix_handler<T>(
    stream_result: std::io::Result<(UnixStream, UnixSocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
) where
    T: PgDataClient,
{
    tokio::spawn(async move {
        if let Err(err) =
            handle_unix_connection::<T>(stream_result, service_context, telemetry).await
        {
            tracing::error!("Failed to accept a Unix socket connection: {err:?}.");
        }
    });
}

/// Detects whether a TLS handshake is being initiated by peeking at the stream.
///
/// This function examines the first three bytes of the TCP stream to determine if
/// the client is initiating a TLS connection. It checks for the standard TLS pattern:
/// - Byte 0: 0x16 (Handshake record type)
/// - Byte 1: 0x03 (SSL/TLS major version)
/// - Byte 2: 0x01-0x04 (TLS minor version for TLS 1.0 through 1.3)
///
/// The client has a limited timeframe to send the first three bytes of the stream.
///
/// # Arguments
///
/// * `tcp_stream` - The TCP stream to examine
/// * `connection_id` - Connection identifier for logging purposes
///
/// # Returns
///
/// Returns `Ok(true)` if first bytes imply TLS, `Ok(false)` otherwise.
///
/// # Errors
///
/// This function will return an error if:
/// * The peek operation fails
/// * The peek operation times out
async fn detect_tls_handshake(tcp_stream: &TcpStream, connection_id: Uuid) -> Result<bool> {
    let mut peek_buf = [0u8; 3];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(TLS_PEEK_TIMEOUT_SECS);

    // Loop to cover the rare cases where peek might not immediately return the full header.
    loop {
        let time_remaining = deadline.saturating_duration_since(tokio::time::Instant::now());

        match tokio::time::timeout(time_remaining, tcp_stream.peek(&mut peek_buf)).await {
            Ok(Ok(0)) => {
                return Err(DocumentDBError::internal_error(
                    "Connection closed".to_owned(),
                ));
            }
            Ok(Ok(n)) => {
                // Return false immediately if any of the seen bytes do not match
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
            Ok(Err(e)) => {
                tracing::warn!(
                    activity_id = connection_id.to_string().as_str(),
                    "Error during TLS detection: {e:?}"
                );
                return Err(DocumentDBError::internal_error(format!(
                    "Error reading from stream {e:?}"
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

        // Successive peeks to a non-empty buffer will return immediately, so we wait before retry.
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Handles a single TCP connection, detecting and setting up TLS if needed
///
/// This function configures the TCP stream with appropriate settings (no delay, keepalive),
/// detects whether the client is attempting a TLS handshake by peeking at the first bytes,
/// and then either establishes a TLS session or proceeds with a plain TCP connection.
///
/// # Arguments
///
/// * `stream_and_address` - Result containing the TCP stream and peer address from `accept()`
/// * `service_context` - Service configuration and shared state
/// * `telemetry` - Optional telemetry provider for metrics collection
///
/// # Returns
///
/// Returns `Ok(())` on successful connection handling, or an error if connection
/// setup or TLS handshake fails.
///
/// # Errors
///
/// This function will return an error if:
/// * TCP stream configuration fails (nodelay, keepalive)
/// * TLS detection fails (peek errors)
/// * SSL/TLS handshake fails
/// * Connection context creation fails
/// * Stream buffering setup fails
async fn handle_connection<T>(
    stream_and_address: std::result::Result<(TcpStream, std::net::SocketAddr), std::io::Error>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
) -> Result<()>
where
    T: PgDataClient,
{
    let (tcp_stream, peer_address) = stream_and_address?;

    let connection_id = Uuid::new_v4();
    tracing::info!(
        activity_id = connection_id.to_string().as_str(),
        "Accepted new TCP connection"
    );

    // Configure TCP stream
    tcp_stream.set_nodelay(true)?;
    let tcp_keepalive = TcpKeepalive::new()
        .with_time(Duration::from_secs(TCP_KEEPALIVE_TIME_SECS))
        .with_interval(Duration::from_secs(TCP_KEEPALIVE_INTERVAL_SECS));

    socket2::SockRef::from(&tcp_stream).set_tcp_keepalive(&tcp_keepalive)?;

    // Detect TLS handshake by peeking at the first bytes
    let is_tls = if service_context.setup_configuration().enforce_tls() {
        true
    } else {
        detect_tls_handshake(&tcp_stream, connection_id).await?
    };

    let ip_address = match peer_address.ip() {
        IpAddr::V4(v4) => IpAddr::V4(v4),
        IpAddr::V6(v6) => {
            // If it's an IPv4-mapped IPv6 (::ffff:a.b.c.d), extract the IPv4.
            if let Some(v4) = v6.to_ipv4_mapped() {
                IpAddr::V4(v4)
            } else {
                IpAddr::V6(v6)
            }
        }
    };

    if is_tls {
        // TLS path
        let tls_acceptor = service_context.tls_provider().tls_acceptor();
        let ssl_session = Ssl::new(tls_acceptor.context())?;
        let mut tls_stream = SslStream::new(ssl_session, tcp_stream)?;

        if let Err(ssl_error) = SslStream::accept(Pin::new(&mut tls_stream)).await {
            tracing::error!("Failed to create TLS connection: {ssl_error:?}.");
            return Err(DocumentDBError::internal_error(format!(
                "SSL handshake failed: {ssl_error:?}."
            )));
        }

        let conn_ctx = ConnectionContext::new(
            service_context,
            telemetry,
            ip_address.to_string(),
            Some(tls_stream.ssl()),
            connection_id,
            "TCP".to_owned(),
        );

        let setup_configuration = conn_ctx.service_context.setup_configuration();

        let buffered_stream = BufStream::with_capacity(
            setup_configuration.stream_read_buffer_size(),
            setup_configuration.stream_write_buffer_size(),
            tls_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        service::handle_stream::<T, _>(buffered_stream, conn_ctx).await;
    } else {
        // Non-TLS path
        let conn_ctx = ConnectionContext::new(
            service_context,
            telemetry,
            ip_address.to_string(),
            None,
            connection_id,
            "TCP".to_owned(),
        );

        let setup_configuration = conn_ctx.service_context.setup_configuration();

        let buffered_stream = BufStream::with_capacity(
            setup_configuration.stream_read_buffer_size(),
            setup_configuration.stream_write_buffer_size(),
            tcp_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "Non-TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        service::handle_stream::<T, _>(buffered_stream, conn_ctx).await;
    }

    Ok(())
}

/// Handles a single Unix socket connection without TLS.
///
/// Unix socket connections are local-only and don't require TLS encryption.
/// This function creates a connection context and processes the connection.
///
/// # Arguments
///
/// * `stream_result` - Result containing the Unix stream from `accept()`
/// * `service_context` - Service configuration and shared state
/// * `telemetry` - Optional telemetry provider for metrics collection
///
/// # Returns
///
/// Returns `Ok(())` on successful connection handling, or an error if connection
/// setup fails.
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

    // For Unix sockets, use localhost as the address since they don't have IP addresses

    let connection_context = ConnectionContext::new(
        service_context,
        telemetry,
        "localhost".to_owned(),
        None, // No TLS for Unix sockets
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
