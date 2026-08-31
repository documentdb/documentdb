/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/body.rs
 *
 *-------------------------------------------------------------------------
 */

//! Collects request bodies and bounds buffered wire responses.

use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};

use bytes::Bytes;
use nacelle::core::{NacelleBody, NacelleError, NacelleResourceLimitReason};
use tokio::io::AsyncWrite;

pub(super) struct BoundedResponseWriter {
    bytes: Vec<u8>,
    max_len: usize,
    failed: bool,
}

impl BoundedResponseWriter {
    /// Creates a response writer bounded by the maximum wire response length.
    ///
    /// # Errors
    ///
    /// Returns a resource-limit error if the initial buffer cannot be reserved.
    pub(super) fn new(
        max_len: usize,
        initial_capacity: usize,
    ) -> std::result::Result<Self, NacelleError> {
        let initial_capacity = initial_capacity.min(max_len);
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(initial_capacity)
            .map_err(|_error| {
                NacelleError::ResourceLimit(NacelleResourceLimitReason::ResponseBodyBytes)
            })?;
        Ok(Self {
            bytes,
            max_len,
            failed: false,
        })
    }

    /// Finalizes the bounded response for delivery.
    ///
    /// # Errors
    ///
    /// Returns a resource-limit error if a prior write exceeded the size bound
    /// or could not reserve buffer capacity.
    pub(super) fn into_response(self) -> std::result::Result<Bytes, NacelleError> {
        if self.failed {
            return Err(NacelleError::ResourceLimit(
                NacelleResourceLimitReason::ResponseBodyBytes,
            ));
        }
        Ok(Bytes::from(self.bytes))
    }

    fn fail(&mut self) -> Poll<io::Result<usize>> {
        self.failed = true;
        self.bytes = Vec::new();
        Poll::Ready(Err(io::Error::other(
            "gateway response size limit exceeded",
        )))
    }

    fn reserve_for(&mut self, required_len: usize) -> bool {
        self.bytes
            .try_reserve_exact(required_len.saturating_sub(self.bytes.len()))
            .is_ok()
    }
}

impl AsyncWrite for BoundedResponseWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _context: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.failed {
            return Poll::Ready(Err(io::Error::other(
                "gateway response size limit exceeded",
            )));
        }
        if self
            .bytes
            .len()
            .checked_add(buf.len())
            .is_none_or(|len| len > self.max_len)
        {
            return self.fail();
        }
        let required_len = self.bytes.len().saturating_add(buf.len());
        if !self.reserve_for(required_len) {
            return self.fail();
        }
        self.bytes.extend_from_slice(buf);
        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// Collects a potentially chunked request body within its declared and explicit limits.
///
/// # Errors
///
/// Returns an error if reading the body fails, its actual or declared length is
/// invalid, it exceeds `max_len`, or the combined buffer cannot be reserved.
pub(super) async fn collect_body(
    mut body: NacelleBody,
    max_len: usize,
) -> std::result::Result<Bytes, NacelleError> {
    let declared_len = body.remaining_bytes();
    if declared_len > max_len {
        return Err(NacelleError::ResourceLimit(
            NacelleResourceLimitReason::RequestBodyBytes,
        ));
    }
    let Some(first_chunk) = body.next_chunk().await else {
        return Ok(Bytes::new());
    };
    let first_chunk = first_chunk?;
    validate_collected_len(first_chunk.len(), declared_len, max_len)?;
    let Some(second_chunk) = body.next_chunk().await else {
        return Ok(first_chunk);
    };
    let second_chunk = second_chunk?;
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(declared_len).map_err(|_error| {
        NacelleError::ResourceLimit(NacelleResourceLimitReason::RequestBodyBytes)
    })?;
    bytes.extend_from_slice(&first_chunk);
    append_chunk(&mut bytes, &second_chunk, declared_len, max_len)?;
    while let Some(chunk) = body.next_chunk().await {
        append_chunk(&mut bytes, &chunk?, declared_len, max_len)?;
    }
    Ok(Bytes::from(bytes))
}

fn append_chunk(
    bytes: &mut Vec<u8>,
    chunk: &[u8],
    declared_len: usize,
    max_len: usize,
) -> std::result::Result<(), NacelleError> {
    let collected_len = bytes
        .len()
        .checked_add(chunk.len())
        .ok_or(NacelleError::ResourceLimit(
            NacelleResourceLimitReason::RequestBodyBytes,
        ))?;
    validate_collected_len(collected_len, declared_len, max_len)?;
    bytes.extend_from_slice(chunk);
    Ok(())
}

const fn validate_collected_len(
    collected_len: usize,
    declared_len: usize,
    max_len: usize,
) -> std::result::Result<(), NacelleError> {
    if collected_len > max_len {
        return Err(NacelleError::ResourceLimit(
            NacelleResourceLimitReason::RequestBodyBytes,
        ));
    }
    if collected_len > declared_len {
        return Err(NacelleError::InvalidFrame(
            "request body exceeds its declared length",
        ));
    }
    Ok(())
}
