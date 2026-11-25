/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway/src/probe.rs
 *
 *-------------------------------------------------------------------------
 */

//! Health probe for a running gateway, for use as a container liveness probe.
//!
//! Unlike `check`, which opens new `PostgreSQL` connections from a separate
//! process, `probe` sends a `ping` command to the gateway that is already
//! running and waits for its reply. It therefore detects a gateway whose
//! request loop has stopped responding even though its port is still open,
//! which a TCP-connect probe cannot. `ping` is answered without touching
//! `PostgreSQL`, so a database outage does not fail the probe.

use std::{
    io::{Read, Write},
    net::{Ipv4Addr, SocketAddr, TcpStream},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use bson::{doc, Document};
use documentdb_gateway_core::configuration::SetupConfiguration;
use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode};

/// Default time allowed for the whole probe: connect, send, and reply.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);

/// Wire protocol opcode for `OP_MSG`.
const OP_MSG: i32 = 2013;

/// Size of the standard message header: length, request id, response to, opcode.
const HEADER_LEN: usize = 16;

/// Largest reply accepted from the gateway. A `ping` reply is a few bytes; the
/// cap only guards against reading an unbounded length from a confused peer.
const MAX_REPLY_LEN: usize = 1024 * 1024;

/// Where the probe connects.
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    /// The gateway's Unix socket listener. No TLS is used.
    Unix(PathBuf),
    /// The gateway's TCP listener on loopback, over TLS.
    Tcp(SocketAddr),
}

impl Target {
    /// Selects the target from the gateway configuration: the Unix socket when
    /// one is configured, otherwise the TCP listener on `127.0.0.1`.
    pub fn from_configuration(configuration: &dyn SetupConfiguration) -> Self {
        configuration.unix_socket_path().map_or_else(
            || {
                Self::Tcp(SocketAddr::from((
                    Ipv4Addr::LOCALHOST,
                    configuration.gateway_listen_port(),
                )))
            },
            |path| Self::Unix(PathBuf::from(path)),
        )
    }
}

impl std::fmt::Display for Target {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unix(path) => write!(f, "unix:{}", path.display()),
            Self::Tcp(addr) => write!(f, "tcp+tls:{addr}"),
        }
    }
}

/// Runs the probe and returns the process exit code: 0 when the gateway
/// answered `ping` with `ok: 1` within `timeout`, 1 otherwise. Prints a single
/// line, which Kubernetes records in the probe event.
pub fn run_probe(target: &Target, timeout: Duration) -> i32 {
    let started = Instant::now();
    match probe(target, timeout) {
        Ok(()) => {
            println!(
                "documentdb-gateway: probe OK ({target}, {} ms)",
                started.elapsed().as_millis()
            );
            0
        }
        Err(reason) => {
            eprintln!("documentdb-gateway: probe FAILED ({target}): {reason}");
            1
        }
    }
}

/// Sends `ping` to `target` and checks the reply.
///
/// # Errors
///
/// Returns a description of the failure when the gateway cannot be reached,
/// does not reply within `timeout`, or replies without `ok: 1`.
pub fn probe(target: &Target, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    match target {
        Target::Unix(path) => {
            let mut stream = connect_unix(path)?;
            exchange(&mut stream, timeout, deadline, |s, t| {
                s.set_read_timeout(Some(t))?;
                s.set_write_timeout(Some(t))
            })
        }
        Target::Tcp(addr) => {
            let tcp = TcpStream::connect_timeout(addr, timeout)
                .map_err(|e| format!("connect to {addr} failed: {e}"))?;
            set_tcp_timeouts(&tcp, remaining(deadline)?)?;
            let mut stream = tls_connect(tcp, timeout)?;
            exchange(&mut stream, timeout, deadline, |s, t| {
                set_tcp_timeouts(s.get_ref(), t).map_err(std::io::Error::other)
            })
        }
    }
}

fn connect_unix(path: &Path) -> Result<UnixStream, String> {
    UnixStream::connect(path).map_err(|e| format!("connect to {} failed: {e}", path.display()))
}

fn set_tcp_timeouts(stream: &TcpStream, timeout: Duration) -> Result<(), String> {
    stream
        .set_read_timeout(Some(timeout))
        .and_then(|()| stream.set_write_timeout(Some(timeout)))
        .map_err(|e| format!("failed to set socket timeout: {e}"))
}

/// Completes a TLS handshake without verifying the certificate. The probe only
/// connects to loopback, where the gateway commonly uses a self-signed or
/// auto-generated certificate whose names do not include `127.0.0.1`.
fn tls_connect(
    tcp: TcpStream,
    timeout: Duration,
) -> Result<openssl::ssl::SslStream<TcpStream>, String> {
    let mut builder = SslConnector::builder(SslMethod::tls_client())
        .map_err(|e| format!("failed to create TLS context: {e}"))?;
    builder.set_verify(SslVerifyMode::NONE);
    let connector = builder.build();
    let config = connector
        .configure()
        .map_err(|e| format!("failed to configure TLS: {e}"))?
        .verify_hostname(false)
        .use_server_name_indication(false);
    config.connect("localhost", tcp).map_err(|e| {
        let timed_out = match &e {
            openssl::ssl::HandshakeError::Failure(mid) => {
                mid.error().io_error().is_some_and(is_timeout)
            }
            openssl::ssl::HandshakeError::WouldBlock(_) => true,
            openssl::ssl::HandshakeError::SetupFailure(_) => false,
        };
        if timed_out {
            format!("TLS handshake timed out after {}", describe(timeout))
        } else {
            format!("TLS handshake failed: {e}")
        }
    })
}

/// Writes the `ping` request and reads one reply, refreshing the socket
/// timeouts from `deadline` before each step so the total stays within it.
fn exchange<S, F>(
    stream: &mut S,
    timeout: Duration,
    deadline: Instant,
    set_timeouts: F,
) -> Result<(), String>
where
    S: Read + Write,
    F: Fn(&S, Duration) -> std::io::Result<()>,
{
    let request = encode_ping()?;
    set_timeouts(stream, remaining(deadline)?)
        .map_err(|e| format!("failed to set socket timeout: {e}"))?;
    stream
        .write_all(&request)
        .map_err(|e| io_failure("failed to send ping", &e, timeout))?;

    let mut header = [0_u8; HEADER_LEN];
    set_timeouts(stream, remaining(deadline)?)
        .map_err(|e| format!("failed to set socket timeout: {e}"))?;
    stream
        .read_exact(&mut header)
        .map_err(|e| io_failure("no reply", &e, timeout))?;
    let length = reply_length(&header)?;

    let mut body = vec![0_u8; length - HEADER_LEN];
    set_timeouts(stream, remaining(deadline)?)
        .map_err(|e| format!("failed to set socket timeout: {e}"))?;
    stream
        .read_exact(&mut body)
        .map_err(|e| io_failure("incomplete reply", &e, timeout))?;

    check_reply(&header, &body)
}

/// Socket reads and writes that hit their timeout fail with `WouldBlock` or
/// `TimedOut`, depending on the platform.
fn is_timeout(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

fn io_failure(what: &str, error: &std::io::Error, timeout: Duration) -> String {
    if is_timeout(error) {
        format!("{what} within {}", describe(timeout))
    } else {
        format!("{what}: {error}")
    }
}

fn describe(timeout: Duration) -> String {
    format!("{}s", timeout.as_secs_f64())
}

fn remaining(deadline: Instant) -> Result<Duration, String> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        Err("timed out".to_owned())
    } else {
        Ok(left)
    }
}

/// Encodes `{ping: 1, $db: "admin"}` as an `OP_MSG` with a single body section.
fn encode_ping() -> Result<Vec<u8>, String> {
    let command = doc! { "ping": 1_i32, "$db": "admin" };
    let mut body = Vec::new();
    command
        .to_writer(&mut body)
        .map_err(|e| format!("failed to encode ping: {e}"))?;

    // flagBits (4) + section kind (1) + document
    let length = HEADER_LEN + 4 + 1 + body.len();
    let length = i32::try_from(length).map_err(|e| format!("ping too large: {e}"))?;
    let mut message = Vec::with_capacity(usize::try_from(length).unwrap_or_default());
    message.extend_from_slice(&length.to_le_bytes());
    message.extend_from_slice(&1_i32.to_le_bytes()); // requestID
    message.extend_from_slice(&0_i32.to_le_bytes()); // responseTo
    message.extend_from_slice(&OP_MSG.to_le_bytes());
    message.extend_from_slice(&0_u32.to_le_bytes()); // flagBits
    message.push(0); // section kind 0: body
    message.extend_from_slice(&body);
    Ok(message)
}

fn reply_length(header: &[u8; HEADER_LEN]) -> Result<usize, String> {
    let length = i32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let length =
        usize::try_from(length).map_err(|e| format!("invalid reply length {length}: {e}"))?;
    if !(HEADER_LEN + 5..=MAX_REPLY_LEN).contains(&length) {
        return Err(format!("invalid reply length {length}"));
    }
    Ok(length)
}

/// Checks that the reply is an `OP_MSG` answering the request with `ok: 1`.
fn check_reply(header: &[u8; HEADER_LEN], body: &[u8]) -> Result<(), String> {
    let response_to = i32::from_le_bytes([header[8], header[9], header[10], header[11]]);
    let op_code = i32::from_le_bytes([header[12], header[13], header[14], header[15]]);
    if op_code != OP_MSG {
        return Err(format!("unexpected reply opcode {op_code}"));
    }
    if response_to != 1 {
        return Err(format!("reply answers request {response_to}, not 1"));
    }
    // body: flagBits (4) + section kind (1) + document
    if body.len() < 5 || body[4] != 0 {
        return Err("reply has no body section".to_owned());
    }
    let reply =
        Document::from_reader(&body[5..]).map_err(|e| format!("invalid reply document: {e}"))?;
    if is_ok(&reply) {
        Ok(())
    } else {
        Err(format!("gateway replied {reply}"))
    }
}

fn is_ok(reply: &Document) -> bool {
    match reply.get("ok") {
        Some(bson::Bson::Double(value)) => (*value - 1.0).abs() < f64::EPSILON,
        Some(bson::Bson::Int32(value)) => *value == 1,
        Some(bson::Bson::Int64(value)) => *value == 1,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        os::unix::net::UnixListener,
        sync::atomic::{AtomicUsize, Ordering},
        thread,
    };

    use super::*;

    static SOCKET_COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn socket_path() -> PathBuf {
        std::env::temp_dir().join(format!(
            "gw-probe-test-{}-{}.sock",
            std::process::id(),
            SOCKET_COUNTER.fetch_add(1, Ordering::Relaxed)
        ))
    }

    /// Builds an `OP_MSG` reply to request 1 carrying `reply`.
    fn op_msg_reply(reply: &Document) -> Vec<u8> {
        let mut body = Vec::new();
        reply.to_writer(&mut body).unwrap();
        let length = i32::try_from(HEADER_LEN + 5 + body.len()).unwrap();
        let mut message = Vec::new();
        message.extend_from_slice(&length.to_le_bytes());
        message.extend_from_slice(&7_i32.to_le_bytes());
        message.extend_from_slice(&1_i32.to_le_bytes());
        message.extend_from_slice(&OP_MSG.to_le_bytes());
        message.extend_from_slice(&0_u32.to_le_bytes());
        message.push(0);
        message.extend_from_slice(&body);
        message
    }

    /// Serves one connection on a Unix socket: reads the request, checks it is a
    /// `ping` `OP_MSG`, then writes `response` (if any) and keeps the socket open
    /// for `hold`.
    fn serve_once(response: Option<Vec<u8>>, hold: Duration) -> PathBuf {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0_u8; HEADER_LEN];
            stream.read_exact(&mut header).unwrap();
            let length =
                usize::try_from(i32::from_le_bytes(header[..4].try_into().unwrap())).unwrap();
            let mut rest = vec![0_u8; length - HEADER_LEN];
            stream.read_exact(&mut rest).unwrap();
            assert_eq!(
                i32::from_le_bytes(header[12..16].try_into().unwrap()),
                OP_MSG
            );
            let request = Document::from_reader(&rest[5..]).unwrap();
            assert_eq!(request.get_i32("ping").unwrap(), 1);
            assert_eq!(request.get_str("$db").unwrap(), "admin");
            if let Some(response) = response {
                stream.write_all(&response).unwrap();
            }
            thread::sleep(hold);
        });
        path
    }

    #[test]
    fn healthy_gateway_passes() {
        let path = serve_once(Some(op_msg_reply(&doc! { "ok": 1.0 })), Duration::ZERO);
        assert_eq!(probe(&Target::Unix(path.clone()), DEFAULT_TIMEOUT), Ok(()));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn error_reply_fails() {
        let path = serve_once(
            Some(op_msg_reply(&doc! { "ok": 0.0, "errmsg": "boom" })),
            Duration::ZERO,
        );
        let err = probe(&Target::Unix(path.clone()), DEFAULT_TIMEOUT).unwrap_err();
        assert!(err.contains("gateway replied"), "{err}");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn unresponsive_gateway_fails_within_timeout() {
        let path = serve_once(None, Duration::from_secs(5));
        let timeout = Duration::from_millis(300);
        let started = Instant::now();
        let err = probe(&Target::Unix(path.clone()), timeout).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "took {:?}",
            started.elapsed()
        );
        assert!(err.contains("no reply within 0.3s"), "{err}");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn missing_socket_fails() {
        let err = probe(&Target::Unix(socket_path()), DEFAULT_TIMEOUT).unwrap_err();
        assert!(err.contains("connect to"), "{err}");
    }

    #[test]
    fn closed_tcp_port_fails() {
        // Bind and drop to get a port nothing is listening on.
        let port = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let target = Target::Tcp(SocketAddr::from((Ipv4Addr::LOCALHOST, port)));
        let err = probe(&target, DEFAULT_TIMEOUT).unwrap_err();
        assert!(err.contains("connect to"), "{err}");
    }

    #[test]
    fn invalid_reply_length_is_rejected() {
        let mut header = [0_u8; HEADER_LEN];
        header[..4].copy_from_slice(&3_i32.to_le_bytes());
        reply_length(&header).unwrap_err();
        header[..4].copy_from_slice(&i32::MAX.to_le_bytes());
        reply_length(&header).unwrap_err();
        header[..4].copy_from_slice(&(-1_i32).to_le_bytes());
        reply_length(&header).unwrap_err();
    }

    #[test]
    fn ok_accepts_numeric_types() {
        assert!(is_ok(&doc! { "ok": 1.0 }));
        assert!(is_ok(&doc! { "ok": 1_i32 }));
        assert!(is_ok(&doc! { "ok": 1_i64 }));
        assert!(!is_ok(&doc! { "ok": 0.0 }));
        assert!(!is_ok(&doc! {}));
    }
}
