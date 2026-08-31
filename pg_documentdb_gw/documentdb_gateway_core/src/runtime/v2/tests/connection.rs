/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/tests/connection.rs
 *
 *-------------------------------------------------------------------------
 */

//! Tests connection cleanup, listener supervision, and transport detection.

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use nacelle::core::NacelleRequestMetricsConfig;
use tokio::{io::AsyncWriteExt, task::JoinSet};
use uuid::Uuid;

use crate::{
    error::Result,
    runtime::v2::{
        connection::gateway_request_metrics,
        listener::{
            create_unix_socket_listener, detect_tls_handshake, drain_completed_connections,
        },
        tests::support::connected_tcp_pair,
    },
};

#[test]
fn request_metrics_follow_gateway_telemetry_setting() {
    for enabled in [false, true] {
        assert_eq!(
            gateway_request_metrics(enabled),
            NacelleRequestMetricsConfig {
                started: enabled,
                completed: enabled,
                in_flight: enabled,
                duration_ms: false,
                byte_counts: enabled,
            }
        );
    }
}

#[tokio::test]
async fn completed_connection_tasks_are_eagerly_drained() {
    const TASK_COUNT: usize = 64;
    let mut tasks = JoinSet::<Result<()>>::new();
    let completed = Arc::new(AtomicUsize::new(0));
    for _ in 0..TASK_COUNT {
        let completed = Arc::clone(&completed);
        tasks.spawn(async move {
            completed.fetch_add(1, Ordering::Release);
            Ok(())
        });
    }
    while completed.load(Ordering::Acquire) != TASK_COUNT {
        tokio::task::yield_now().await;
    }
    tokio::task::yield_now().await;

    drain_completed_connections(&mut tasks);

    assert!(tasks.is_empty());
}

#[tokio::test]
async fn tls_detection_distinguishes_plaintext() {
    let (mut client, server) = connected_tcp_pair().await;
    client
        .write_all(&[0x01, 0x00, 0x00])
        .await
        .expect("plaintext prefix should write");

    assert!(!detect_tls_handshake(&server, Uuid::new_v4())
        .await
        .expect("plaintext detection should succeed"));
}

#[tokio::test]
async fn tls_detection_accepts_handshake_prefix() {
    let (mut client, server) = connected_tcp_pair().await;
    client
        .write_all(&[0x16, 0x03, 0x03])
        .await
        .expect("TLS prefix should write");

    assert!(detect_tls_handshake(&server, Uuid::new_v4())
        .await
        .expect("TLS detection should succeed"));
}

#[cfg(unix)]
#[tokio::test]
async fn unix_listener_applies_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let path = std::env::temp_dir().join(format!(
        "documentdb-runtime-serial-test-{}.sock",
        std::process::id()
    ));
    let path_string = path.to_string_lossy();
    let listener =
        create_unix_socket_listener(&path_string, 0o640).expect("Unix listener should bind");

    assert_eq!(
        std::fs::metadata(&path)
            .expect("socket metadata should exist")
            .permissions()
            .mode()
            & 0o777,
        0o640
    );

    drop(listener);
    std::fs::remove_file(path).expect("test socket should be removed");
}
