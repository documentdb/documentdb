/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/tests/body.rs
 *
 *-------------------------------------------------------------------------
 */

//! Tests bounded request collection and response buffering.

use bytes::Bytes;
use nacelle::core::{NacelleBody, NacelleError, NacelleResourceLimitReason};
use tokio::io::AsyncWriteExt;

use crate::runtime::v2::body::{collect_body, BoundedResponseWriter};

#[tokio::test]
async fn collected_body_returns_single_chunk_without_copying() {
    let source = Bytes::from_static(b"body");
    let source_pointer = source.as_ptr();

    let collected = collect_body(NacelleBody::bytes(source), 4)
        .await
        .expect("single chunk should collect");

    assert_eq!(collected, Bytes::from_static(b"body"));
    assert_eq!(collected.as_ptr(), source_pointer);
}

#[tokio::test]
async fn collected_body_combines_multiple_chunks() {
    let body = NacelleBody::from_buffered(
        vec![Bytes::from_static(b"res"), Bytes::from_static(b"ponse")],
        8,
    );

    let collected = collect_body(body, 8)
        .await
        .expect("multiple chunks should collect");

    assert_eq!(collected, Bytes::from_static(b"response"));
}

#[tokio::test]
async fn collected_body_rejects_data_beyond_declared_length() {
    let body = NacelleBody::from_buffered(
        vec![Bytes::from_static(b"abc"), Bytes::from_static(b"def")],
        5,
    );

    assert!(matches!(
        collect_body(body, 8).await,
        Err(NacelleError::InvalidFrame(_))
    ));
}

#[tokio::test]
async fn collected_body_rejects_data_beyond_explicit_limit() {
    let body = NacelleBody::from_buffered(
        vec![Bytes::from_static(b"abc"), Bytes::from_static(b"def")],
        5,
    );

    assert!(matches!(
        collect_body(body, 5).await,
        Err(NacelleError::ResourceLimit(
            NacelleResourceLimitReason::RequestBodyBytes
        ))
    ));
}

#[tokio::test]
async fn bounded_response_writer_accepts_within_limit() {
    let mut writer =
        BoundedResponseWriter::new(8, 4).expect("initial response reservation should fit");
    writer
        .write_all(b"res")
        .await
        .expect("first response chunk should fit");
    writer
        .write_all(b"ponse")
        .await
        .expect("response should fit");

    let response = writer
        .into_response()
        .expect("bounded response should finalize");

    assert_eq!(response.len(), 8);
    assert_eq!(response, Bytes::from_static(b"response"));
}

#[tokio::test]
async fn bounded_response_writer_rejects_over_limit() {
    let mut writer =
        BoundedResponseWriter::new(4, 4).expect("initial response reservation should fit");

    assert!(writer.write_all(b"large").await.is_err());
    assert!(matches!(
        writer
            .into_response()
            .expect_err("failed response must not finalize"),
        NacelleError::ResourceLimit(NacelleResourceLimitReason::ResponseBodyBytes)
    ));
}
