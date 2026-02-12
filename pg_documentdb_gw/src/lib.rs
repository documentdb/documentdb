/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/lib.rs
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

pub use crate::postgres::QueryCatalog;

use std::{net::IpAddr, pin::Pin, sync::Arc};

use either::Either::{Left, Right};
use openssl::ssl::Ssl;
use socket2::TcpKeepalive;
use tokio::{
    io::{AsyncRead, AsyncWrite, BufStream},
    net::{TcpListener, TcpStream, UnixListener, UnixStream},
    time::{Duration, Instant},
};
use tokio_openssl::SslStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::{ConnectionContext, RequestContext, ServiceContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request, RequestIntervalKind},
    responses::{CommandError, Response},
    telemetry::{
        client_info::parse_client_info, error_code_to_status_code, event_id::EventId,
        TelemetryProvider,
    },
};

// TCP keepalive configuration constants
const TCP_KEEPALIVE_TIME_SECS: u64 = 180;
const TCP_KEEPALIVE_INTERVAL_SECS: u64 = 60;

// Buffer configuration constants
const STREAM_READ_BUFFER_SIZE: usize = 8 * 1024;
const STREAM_WRITE_BUFFER_SIZE: usize = 8 * 1024;

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

/// Runs the DocumentDB gateway server, accepting and handling incoming connections.
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
    // TCP configuration part
    let tcp_listener = TcpListener::bind(format!(
        "{}:{}",
        if service_context.setup_configuration().use_local_host() {
            "127.0.0.1"
        } else {
            "[::]"
        },
        service_context.setup_configuration().gateway_listen_port(),
    ))
    .await?;

    tracing::info!(
        "TCP listener bound to port {}",
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
            stream_and_address = tcp_listener.accept() => {
                let conn_service_context = service_context.clone();
                let conn_telemetry = telemetry.clone();
                tokio::spawn(async move {
                    let conn_res = handle_connection::<T>(
                        stream_and_address,
                        conn_service_context,
                        conn_telemetry,
                    )
                    .await;

                    if let Err(conn_err) = conn_res {
                        tracing::error!("Failed to accept a TCP connection: {conn_err:?}.");
                    }
                });
            }
            stream_result = async {
                match &unix_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if unix_listener.is_some() => {
                let conn_service_context = service_context.clone();
                let conn_telemetry = telemetry.clone();
                tokio::spawn(async move {
                    let conn_res = handle_unix_connection::<T>(
                        stream_result,
                        conn_service_context,
                        conn_telemetry,
                    )
                    .await;

                    if let Err(conn_err) = conn_res {
                        tracing::error!("Failed to accept a Unix socket connection: {conn_err:?}.");
                    }
                });
            }
            () = token.cancelled() => {
                return Ok(())
            }
        }
    }
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
                    "Connection closed".to_string(),
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
                    "Timeout reading from stream".to_string(),
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
/// * `stream_and_address` - Result containing the TCP stream and peer address from accept()
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
            "TCP".to_string(),
        );

        let buffered_stream = BufStream::with_capacity(
            STREAM_READ_BUFFER_SIZE,
            STREAM_WRITE_BUFFER_SIZE,
            tls_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        handle_stream::<T, _>(buffered_stream, conn_ctx).await;
    } else {
        // Non-TLS path
        let conn_ctx = ConnectionContext::new(
            service_context,
            telemetry,
            ip_address.to_string(),
            None,
            connection_id,
            "TCP".to_string(),
        );

        let buffered_stream = BufStream::with_capacity(
            STREAM_READ_BUFFER_SIZE,
            STREAM_WRITE_BUFFER_SIZE,
            tcp_stream,
        );

        tracing::info!(
            activity_id = connection_id.to_string().as_str(),
            "Non-TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}"
        );

        handle_stream::<T, _>(buffered_stream, conn_ctx).await;
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
/// * `stream_result` - Result containing the Unix stream from accept()
/// * `service_context` - Service configuration and shared state
/// * `telemetry` - Optional telemetry provider for metrics collection
///
/// # Returns
///
/// Returns `Ok(())` on successful connection handling, or an error if connection
/// setup fails.
async fn handle_unix_connection<T>(
    stream_result: std::result::Result<(UnixStream, tokio::net::unix::SocketAddr), std::io::Error>,
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
        "localhost".to_string(),
        None, // No TLS for Unix sockets
        connection_id,
        "UnixSocket".to_string(),
    );

    let buffered_stream = BufStream::with_capacity(
        STREAM_READ_BUFFER_SIZE,
        STREAM_WRITE_BUFFER_SIZE,
        unix_stream,
    );

    tracing::info!(
        activity_id = connection_id.to_string().as_str(),
        "Unix socket connection established - Connection Id {connection_id}"
    );

    handle_stream::<T, _>(buffered_stream, connection_context).await;
    Ok(())
}

async fn handle_stream<T, S>(mut stream: S, mut connection_context: ConnectionContext)
where
    T: PgDataClient,
    S: AsyncRead + AsyncWrite + Unpin,
{
    let connection_activity_id = connection_context.connection_id.to_string();
    let connection_activity_id_as_str = connection_activity_id.as_str();

    loop {
        match protocol::reader::read_header(&mut stream).await {
            Ok(Some(header)) => {
                let request_activity_id =
                    connection_context.generate_request_activity_id(header.request_id);

                if let Err(e) = handle_message::<T, S>(
                    &mut connection_context,
                    &header,
                    &mut stream,
                    &request_activity_id,
                )
                .await
                {
                    if let Err(e) = log_and_write_error::<S>(
                        &connection_context,
                        &header,
                        &e,
                        None,
                        &mut stream,
                        None,
                        &RequestTracker::new(),
                        &request_activity_id,
                        None,
                    )
                    .await
                    {
                        tracing::error!(
                            activity_id = request_activity_id.as_str(),
                            "Couldn't reply with error {e:?}."
                        );
                        break;
                    }
                }
            }

            Ok(None) => {
                tracing::info!(
                    activity_id = connection_activity_id_as_str,
                    "Connection closed."
                );
                break;
            }

            Err(e) => {
                if let Err(e) = responses::writer::write_error_without_header(
                    &connection_context,
                    e,
                    &mut stream,
                    connection_activity_id_as_str,
                )
                .await
                {
                    tracing::warn!(
                        activity_id = connection_activity_id_as_str,
                        "Couldn't reply with error {e:?}."
                    );
                    break;
                }
            }
        }
    }
}

async fn get_response<T>(
    request_context: &RequestContext<'_>,
    connection_context: &mut ConnectionContext,
) -> Result<Response>
where
    T: PgDataClient,
{
    if request_context.payload.request_type().handle_with_auth() {
        let response = auth::process::<T>(connection_context, request_context).await?;
        return Ok(response);
    }

    if !*connection_context.auth_state.is_authorized().read().await {
        if *connection_context.auth_state.auth_kind() == Some(auth::AuthKind::ExternalIdentity) {
            return Err(DocumentDBError::reauthentication_required(
                "External identity token has expired.".to_string(),
            ));
        } else {
            let response = auth::process::<T>(connection_context, request_context).await?;
            return Ok(response);
        }
    }

    // Once authorized, make sure that there is a pool of pg clients for the user/password.
    connection_context.allocate_data_pool().await?;

    let service_context = Arc::clone(&connection_context.service_context);
    let data_client = T::new_authorized(&service_context, &connection_context.auth_state).await?;

    // Process the actual request
    let response =
        processor::process_request(request_context, connection_context, data_client).await?;

    Ok(response)
}

async fn handle_message<T, S>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    stream: &mut S,
    activity_id: &str,
) -> Result<()>
where
    T: PgDataClient,
    S: AsyncRead + AsyncWrite + Unpin,
{
    let request_tracker = RequestTracker::new();

    // Read the request message off the stream
    let read_request_start = Instant::now();
    let message = protocol::reader::read_request(header, stream).await?;
    request_tracker.record_duration(RequestIntervalKind::ReadRequest, read_request_start);

    // HandleMessage captures the overall duration needed by the server to handle/process
    // a user operation message/request. Client-to-Gateway networking latency should be
    // excluded from HandleMessage; therefore, ReadRequest is closed before this starts,
    // and WriteResponse starts measuring only after HandleMessage is closed.
    let handle_message_start = Instant::now();
    if connection_context
        .dynamic_configuration()
        .send_shutdown_responses()
        .await
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::ShutdownInProgress,
            "Graceful shutdown requested".to_string(),
        ));
    }

    let format_request_start = Instant::now();
    let request =
        protocol::reader::parse_request(&message, &mut connection_context.requires_response)
            .await?;
    request_tracker.record_duration(RequestIntervalKind::FormatRequest, format_request_start);

    let request_info = request.extract_common()?;
    let request_context = RequestContext {
        activity_id,
        payload: &request,
        info: &request_info,
        tracker: &request_tracker,
    };

    let mut collection = String::new();

    let request_result = handle_request::<T, S>(
        connection_context,
        header,
        &request_context,
        stream,
        &mut collection,
        handle_message_start,
    )
    .await;

    // Errors in request handling are handled explicitly so that telemetry can have access to the request
    // Returns Ok afterwards so that higher level error telemetry is not invoked.
    let command_error = if let Err(e) = request_result {
        match log_and_write_error::<S>(
            connection_context,
            header,
            &e,
            Some(request_context.payload),
            stream,
            Some(collection),
            request_context.tracker,
            activity_id,
            Some(handle_message_start),
        )
        .await
        {
            Ok(command_error) => Some(command_error),
            Err(write_err) => {
                tracing::error!(
                    activity_id = activity_id,
                    "Couldn't reply with error {write_err:?}."
                );
                None
            }
        }
    } else {
        None
    };

    if connection_context
        .dynamic_configuration()
        .enable_verbose_logging_in_gateway()
        .await
    {
        log_verbose_latency(connection_context, &request_context, command_error.as_ref()).await;
    }

    Ok(())
}

async fn handle_request<T, S>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    request_context: &RequestContext<'_>,
    stream: &mut S,
    collection: &mut String,
    handle_message_start: tokio::time::Instant,
) -> Result<()>
where
    T: PgDataClient,
    S: AsyncRead + AsyncWrite + Unpin,
{
    *collection = request_context.info.collection().unwrap_or("").to_string();

    // Process the request
    let handle_request_start = Instant::now();
    let response_result = get_response::<T>(request_context, connection_context).await;
    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleRequest, handle_request_start);

    let response = match response_result {
        Ok(response) => response,
        // For the error case, the error handling code will close HandleMessage.
        Err(e) => {
            return Err(e);
        }
    };

    // Write the response back to the stream
    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleMessage, handle_message_start);

    if connection_context.requires_response {
        let write_response_start = Instant::now();
        responses::writer::write(header, &response, stream).await?;
        request_context
            .tracker
            .record_duration(RequestIntervalKind::WriteResponse, write_response_start);
    }

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        telemetry
            .emit_request_event(
                connection_context,
                header,
                Some(request_context.payload),
                Left(&response),
                collection.to_string(),
                request_context.tracker,
                request_context.activity_id,
                &parse_client_info(connection_context.client_information.as_ref()),
            )
            .await;
    }

    Ok(())
}

#[expect(clippy::too_many_arguments)]
async fn log_and_write_error<S>(
    connection_context: &ConnectionContext,
    header: &Header,
    e: &DocumentDBError,
    request: Option<&Request<'_>>,
    stream: &mut S,
    collection: Option<String>,
    request_tracker: &RequestTracker,
    activity_id: &str,
    handle_message_start: Option<Instant>,
) -> Result<CommandError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let command_error = CommandError::from_error(connection_context, e, activity_id).await;
    let response = command_error.to_raw_document_buf();

    if let Some(start) = handle_message_start {
        request_tracker.record_duration(RequestIntervalKind::HandleMessage, start);
    }

    let write_response_start = Instant::now();
    responses::writer::write_and_flush(header, &response, stream).await?;
    request_tracker.record_duration(RequestIntervalKind::WriteResponse, write_response_start);

    // telemetry can block so do it after write and flush.
    tracing::error!(activity_id = activity_id, "Request failure: {e}");

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        telemetry
            .emit_request_event(
                connection_context,
                header,
                request,
                Right((&command_error, response.as_bytes().len())),
                collection.unwrap_or_default(),
                request_tracker,
                activity_id,
                &parse_client_info(connection_context.client_information.as_ref()),
            )
            .await;
    }

    Ok(command_error)
}

async fn log_verbose_latency(
    connection_context: &ConnectionContext,
    request_context: &RequestContext<'_>,
    e: Option<&CommandError>,
) {
    let database_name = request_context.info.db().unwrap_or_default();
    let collection_name = request_context.info.collection().unwrap_or_default();
    let request_type = request_context.payload.request_type().to_string();

    let (status_code, error_code) = if let Some(error) = e {
        let code = error.code;
        (error_code_to_status_code(code.into()), code)
    } else {
        (200, 0)
    };

    tracing::info!(
        activity_id = request_context.activity_id,
        event_id = EventId::RequestTrace.code(),
        "Latency for Mongo Request with interval timings (ns): ReadRequest={}, HandleMessage={} FormatRequest={}, HandleRequest={}, ProcessRequest={}, PostgresBeginTransaction={}, PostgresSetStatementTimeout={}, PostgresCommitTransaction={}, WriteResponse={}, Address={}, TransportProtocol={}, DatabaseName={}, CollectionName={}, OperationName={}, StatusCode={}, SubStatusCode={}, ErrorCode={}",
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::ReadRequest),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::HandleMessage),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::FormatRequest),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::HandleRequest),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::ProcessRequest),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresBeginTransaction),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresSetStatementTimeout),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresCommitTransaction),
        request_context.tracker.get_interval_elapsed_time(RequestIntervalKind::WriteResponse),
        connection_context.ip_address,
        connection_context.transport_protocol(),
        database_name,
        collection_name,
        request_type,
        status_code,
        0, // SubStatusCode is not used currently in Rust
        error_code
    );
}
