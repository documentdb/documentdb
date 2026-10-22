/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/runtime/v1.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{net::IpAddr, pin::Pin, sync::Arc, time::Duration};

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
    runtime::connection_log::ConnectionLog,
    service::{self, ListenerConfig, RequestRouter, TlsProvider},
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
pub async fn run_gateway<T, R>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: R,
    token: CancellationToken,
) -> Result<()>
where
    T: PgDataClient + 'static,
    R: RequestRouter<T> + Send + 'static,
{
    let request_router = Arc::new(request_router);
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
                spawn_tcp_handler::<T, R>(
                    result,
                    service_context.clone(),
                    telemetry.clone(),
                    Arc::clone(&request_router),
                    "IPv4",
                );
            }
            result = async {
                match &ipv6_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if ipv6_listener.is_some() => {
                spawn_tcp_handler::<T, R>(
                    result,
                    service_context.clone(),
                    telemetry.clone(),
                    Arc::clone(&request_router),
                    "IPv6",
                );
            }
            result = async {
                match &unix_listener {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                }
            }, if unix_listener.is_some() => {
                spawn_unix_handler::<T, R>(
                    result,
                    service_context.clone(),
                    telemetry.clone(),
                    Arc::clone(&request_router),
                );
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
/// like the Geneva provider can emit to their own sinks in addition to the
/// global metrics recorder); otherwise records through the metrics facade
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

fn spawn_tcp_handler<T, R>(
    stream_and_address: std::io::Result<(TcpStream, std::net::SocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: Arc<R>,
    protocol: &'static str,
) where
    T: PgDataClient + 'static,
    R: RequestRouter<T> + Send + 'static,
{
    match stream_and_address {
        Ok((stream, peer)) => {
            tokio::spawn(handle_connection::<T, R>(
                stream,
                peer,
                service_context,
                telemetry,
                request_router,
            ));
        }
        Err(error) => {
            tracing::error!("Failed to accept a TCP connection ({protocol}): {error:?}.");
        }
    }
}

fn spawn_unix_handler<T, R>(
    stream_result: std::io::Result<(UnixStream, UnixSocketAddr)>,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: Arc<R>,
) where
    T: PgDataClient + 'static,
    R: RequestRouter<T> + Send + 'static,
{
    match stream_result {
        Ok((stream, _)) => {
            tokio::spawn(handle_unix_connection::<T, R>(
                stream,
                service_context,
                telemetry,
                request_router,
            ));
        }
        Err(error) => {
            tracing::error!("Failed to accept a Unix socket connection: {error:?}.");
        }
    }
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

async fn handle_connection<T, R>(
    tcp_stream: TcpStream,
    peer_address: std::net::SocketAddr,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: Arc<R>,
) where
    T: PgDataClient + 'static,
    R: RequestRouter<T>,
{
    let connection_id = Uuid::new_v4();
    let ip_address = match peer_address.ip() {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        ip @ IpAddr::V4(_) => ip,
    };
    let mut connection_log = ConnectionLog::new(connection_id, ip_address.to_string(), "TCP");
    let result = handle_tcp_stream::<T, R>(
        tcp_stream,
        ip_address,
        service_context,
        telemetry,
        request_router,
        connection_id,
        &mut connection_log,
    )
    .await;
    connection_log.finish(&result);
}

async fn handle_tcp_stream<T, R>(
    tcp_stream: TcpStream,
    ip_address: IpAddr,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: Arc<R>,
    connection_id: Uuid,
    connection_log: &mut ConnectionLog,
) -> Result<()>
where
    T: PgDataClient + 'static,
    R: RequestRouter<T>,
{
    tracing::debug!(
        activity_id = connection_id.to_string().as_str(),
        "Accepted new TCP connection"
    );

    apply_tcp_options(&tcp_stream)?;

    let is_tls = if service_context.setup_configuration().enforce_tls() {
        true
    } else {
        detect_tls_handshake(&tcp_stream, connection_id).await?
    };

    if is_tls {
        let tls_acceptor = service_context.tls_provider().tls_acceptor();
        let ssl_session = Ssl::new(tls_acceptor.context())?;
        let mut tls_stream = SslStream::new(ssl_session, tcp_stream)?;

        let handshake_result = SslStream::accept(Pin::new(&mut tls_stream)).await;
        connection_log.record_tls(tls_stream.ssl());
        if let Err(ssl_error) = handshake_result {
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
            "TLS TCP connection established - Connection Id {connection_id}, client IP {ip_address}, HostNameFromSni {}",
            TlsProvider::sni_host_name_for_logging(buffered_stream.get_ref().ssl())
        );

        service::handle_stream::<T, R, _>(
            buffered_stream,
            connection_context,
            request_router.as_ref(),
        )
        .await;
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

        service::handle_stream::<T, R, _>(
            buffered_stream,
            connection_context,
            request_router.as_ref(),
        )
        .await;
    }

    Ok(())
}

async fn handle_unix_connection<T, R>(
    unix_stream: UnixStream,
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    request_router: Arc<R>,
) where
    T: PgDataClient,
    R: RequestRouter<T>,
{
    let connection_id = Uuid::new_v4();
    let mut connection_log =
        ConnectionLog::new(connection_id, "localhost".to_owned(), "UnixSocket");
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

    service::handle_stream::<T, R, _>(buffered_stream, connection_context, request_router.as_ref())
        .await;
    connection_log.finish(&Ok(()));
}

#[cfg(test)]
mod tests {
    use openssl::ssl::{SslConnector, SslMethod};
    use tokio::net::TcpListener;
    use tracing_subscriber::prelude::*;

    use super::*;
    use crate::{
        postgres::DocumentDBDataClient,
        service::DefaultRequestRouter,
        testing::{logs::LogCapture, test_connection_context, TestDynamicConfiguration},
    };

    #[tokio::test]
    async fn connection_logs_cover_tcp_setup_failure_and_unix_eof() {
        let context =
            test_connection_context(false, Arc::new(TestDynamicConfiguration::default()), None)
                .await;
        let service_context = context.service_context.as_ref().clone();
        let capture = LogCapture::new("documentdb_gateway_core::runtime::connection_log");
        let _guard =
            tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
        tracing::callsite::rebuild_interest_cache();

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let client = TcpStream::connect(listener.local_addr().expect("local address"))
            .await
            .expect("connect");
        let (stream, peer) = listener.accept().await.expect("accept");
        let client_ssl = SslConnector::builder(SslMethod::tls_client())
            .expect("client TLS builder")
            .build()
            .configure()
            .expect("client TLS configuration")
            .into_ssl("diagnostic.example.com")
            .expect("client SSL");
        let mut client = SslStream::new(client_ssl, client).expect("TLS client");
        let (server_result, client_result) = tokio::join!(
            tokio::time::timeout(
                Duration::from_secs(5),
                handle_connection::<DocumentDBDataClient, _>(
                    stream,
                    peer,
                    service_context.clone(),
                    None,
                    Arc::new(DefaultRequestRouter {}),
                ),
            ),
            tokio::time::timeout(Duration::from_secs(5), Pin::new(&mut client).connect())
        );
        server_result.expect("failed TLS setup should terminate");
        assert!(
            client_result
                .expect("client handshake should finish")
                .is_err(),
            "the client must reject the untrusted server certificate"
        );

        let (client, server) = UnixStream::pair().expect("socket pair");
        drop(client);
        tokio::time::timeout(
            Duration::from_secs(5),
            handle_unix_connection::<DocumentDBDataClient, _>(
                server,
                service_context,
                None,
                Arc::new(DefaultRequestRouter {}),
            ),
        )
        .await
        .expect("Unix EOF should terminate");

        let events = capture.events();
        assert_eq!(events.len(), 3, "{events:?}");
        assert_eq!(events[0].level, tracing::Level::ERROR);
        assert_eq!(events[1].level, tracing::Level::INFO);
        assert_eq!(events[1].fields["close_reason"], "error");
        assert_eq!(events[1].fields["transport"], "TCP");
        assert_eq!(events[1].fields["client_ip"], "127.0.0.1");
        assert_eq!(
            events[1].fields["host_name_from_sni"],
            "diagnostic.example.com"
        );
        assert_eq!(
            events[0].fields["connection_id"],
            events[1].fields["connection_id"]
        );
        assert_eq!(events[2].level, tracing::Level::INFO);
        assert_eq!(events[2].fields["close_reason"], "completed");
        assert_eq!(events[2].fields["transport"], "UnixSocket");
        assert_ne!(
            events[1].fields["connection_id"],
            events[2].fields["connection_id"]
        );
    }
}
