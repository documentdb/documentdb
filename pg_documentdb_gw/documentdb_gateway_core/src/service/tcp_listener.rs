/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/service/tcp_listener.rs
 *
 * TCP listener creation utilities with cross-platform IPv4/IPv6 support.
 *
 *-------------------------------------------------------------------------
 */

use std::net::{Ipv6Addr, SocketAddr, SocketAddrV6};

use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::TcpListener;

use crate::error::{DocumentDBError, Result};

/// Creates TCP listeners bound to the appropriate addresses.
///
/// For localhost mode, binds to `127.0.0.1` only.
/// For non-localhost mode, attempts to bind to both IPv6 (`[::]`) and IPv4 (`0.0.0.0`).
/// IPv6 socket is explicitly set to IPv6-only mode (`IPV6_V6ONLY`) for consistent
/// behavior across platforms (Linux defaults to dual-stack, Windows/macOS to IPv6-only).
/// If one fails, logs a warning and continues with the other.
/// Returns an error only if both bindings fail.
///
/// # Returns
/// A tuple of (IPv4 listener, IPv6 listener) where either may be `None` if binding failed.
///
/// # Errors
/// Returns an error if:
/// - In localhost mode: binding to `127.0.0.1` fails.
/// - In non-localhost mode: both IPv4 and IPv6 bindings fail.
pub async fn create_tcp_listeners(
    use_local_host: bool,
    port: u16,
) -> Result<(Option<TcpListener>, Option<TcpListener>)> {
    if use_local_host {
        let listener = TcpListener::bind(format!("127.0.0.1:{port}")).await?;
        tracing::info!("Bound to localhost address 127.0.0.1:{port}.");
        Ok((Some(listener), None))
    } else {
        // Bind IPv6 with explicit IPV6_V6ONLY to ensure consistent behavior across platforms.
        // On Linux, IPv6 sockets default to dual-stack (accepting IPv4 too), while
        // Windows/macOS default to IPv6-only. Setting V6ONLY ensures we need both listeners.
        let ipv6_listener = match create_ipv6_only_listener(port) {
            Ok(listener) => {
                tracing::info!("Bound to IPv6 address [::]:{}.", port);
                Some(listener)
            }
            Err(err) => {
                tracing::warn!(
                    "Failed to bind to IPv6 address [::]:{}. IPv6 may not be supported. Error: {}",
                    port,
                    err
                );
                None
            }
        };

        // Bind IPv4
        let ipv4_listener = match TcpListener::bind(format!("0.0.0.0:{port}")).await {
            Ok(listener) => {
                tracing::info!("Bound to IPv4 address 0.0.0.0:{port}.");
                Some(listener)
            }
            Err(err) => {
                tracing::warn!(
                    "Failed to bind to IPv4 address 0.0.0.0:{port}. IPv4 may not be supported. Error: {err}"
                );
                None
            }
        };

        if ipv6_listener.is_none() && ipv4_listener.is_none() {
            return Err(DocumentDBError::internal_error(format!(
                "Failed to bind to any address on port {port}"
            )));
        }

        Ok((ipv4_listener, ipv6_listener))
    }
}

/// Creates an IPv6 TCP listener with `IPV6_V6ONLY` set to true.
///
/// This ensures the socket only accepts IPv6 connections, matching Windows/macOS behavior
/// and allowing a separate IPv4 listener to coexist on the same port.
fn create_ipv6_only_listener(port: u16) -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;

    // Set IPV6_V6ONLY to true - this socket will only accept IPv6 connections
    socket.set_only_v6(true)?;

    // Allow address reuse for faster restarts
    socket.set_reuse_address(true)?;

    // Bind to [::]:port
    let addr = SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0));
    socket.bind(&addr.into())?;

    // Start listening. Backlog of 4096 matches Linux kernel default (SOMAXCONN since 5.4).
    socket.listen(4096)?;

    // Set non-blocking for tokio compatibility
    socket.set_nonblocking(true)?;

    // Convert to tokio TcpListener
    let std_listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(std_listener)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;

    #[tokio::test]
    async fn test_create_tcp_listeners_localhost_binds_to_ipv4_loopback_only() {
        let (ipv4_listener, ipv6_listener) = create_tcp_listeners(true, 0).await.unwrap();

        // Localhost mode should return only IPv4 listener
        assert!(ipv4_listener.is_some(), "IPv4 listener should be present");
        assert!(
            ipv6_listener.is_none(),
            "IPv6 listener should be None for localhost"
        );

        let addr = ipv4_listener.unwrap().local_addr().unwrap();
        assert_eq!(addr.ip(), IpAddr::from([127, 0, 0, 1]));
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_non_localhost_returns_at_least_one_listener() {
        let (ipv4_listener, ipv6_listener) = create_tcp_listeners(false, 0).await.unwrap();

        // At least one listener should be present
        assert!(
            ipv4_listener.is_some() || ipv6_listener.is_some(),
            "At least one listener should be present"
        );

        // Verify addresses are correct for whichever listeners are present
        if let Some(listener) = &ipv4_listener {
            let addr = listener.local_addr().unwrap();
            assert_eq!(addr.ip(), IpAddr::from([0, 0, 0, 0]));
        }
        if let Some(listener) = &ipv6_listener {
            let addr = listener.local_addr().unwrap();
            assert!(addr.ip().is_ipv6());
        }
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_assigns_port() {
        let (ipv4_listener, _) = create_tcp_listeners(true, 0).await.unwrap();
        let addr = ipv4_listener.unwrap().local_addr().unwrap();
        assert_ne!(addr.port(), 0, "OS should assign a non-zero port");
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_specific_port_localhost() {
        // Bind to port 0 first to get an available port from the OS
        let temp_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = temp_listener.local_addr().unwrap().port();
        drop(temp_listener);

        // Now bind using our function with that specific port
        let (ipv4_listener, _) = create_tcp_listeners(true, port).await.unwrap();
        let addr = ipv4_listener.unwrap().local_addr().unwrap();
        assert_eq!(addr.port(), port);
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_localhost_does_not_bind_to_all_interfaces() {
        let (ipv4_listener, ipv6_listener) = create_tcp_listeners(true, 0).await.unwrap();

        // Localhost mode must NOT bind to all interfaces
        assert!(ipv4_listener.is_some());
        assert!(ipv6_listener.is_none());

        let addr = ipv4_listener.unwrap().local_addr().unwrap();
        assert!(
            !addr.ip().is_unspecified(),
            "Localhost mode should not bind to unspecified address, got {}",
            addr.ip()
        );
        assert!(addr.ip().is_loopback());
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_non_localhost_warns_but_succeeds_if_one_fails() {
        // This test verifies the behavior when one listener fails but the other succeeds.
        // We simulate this by first binding to IPv6 on a specific port, then calling
        // create_tcp_listeners on the same port - IPv6 should fail but IPv4 should succeed.
        let ipv6_pre_bound = create_ipv6_only_listener(0);
        if let Ok(ipv6_pre_bound) = ipv6_pre_bound {
            let port = ipv6_pre_bound.local_addr().unwrap().port();

            // Now try to create listeners on the same port
            // IPv6 bind will fail (port taken), but IPv4 should succeed
            let result = create_tcp_listeners(false, port).await;

            // The function should succeed as long as at least one listener works
            if let Ok((ipv4_listener, ipv6_listener)) = result {
                // IPv6 should have failed (port was already taken)
                assert!(
                    ipv6_listener.is_none(),
                    "IPv6 listener should fail when port is already bound"
                );
                // IPv4 should have succeeded
                assert!(
                    ipv4_listener.is_some(),
                    "IPv4 listener should succeed even when IPv6 fails"
                );
            }
            drop(ipv6_pre_bound);
        }
        // If IPv6 isn't available at all, the test still passes —
        // create_tcp_listeners handles this gracefully
    }

    #[tokio::test]
    async fn test_create_tcp_listeners_fails_when_both_fail() {
        // Use a specific port so both bindings use the same port
        const TEST_PORT: u16 = 22345;

        // Bind both IPv4 and IPv6 to the same port first
        let ipv4_pre_bound = TcpListener::bind(format!("0.0.0.0:{TEST_PORT}")).await;
        let ipv6_pre_bound = create_ipv6_only_listener(TEST_PORT);

        if let (Ok(_ipv4_pre), Ok(_ipv6_pre)) = (&ipv4_pre_bound, &ipv6_pre_bound) {
            // Both ports are now taken, create_tcp_listeners should fail
            let result = create_tcp_listeners(false, TEST_PORT).await;
            assert!(result.is_err(), "Should fail when both addresses are taken");
        }
        // If either pre-bind failed (port already in use by another process),
        // skip the test - we can't guarantee port availability in CI
    }
}
