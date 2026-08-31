/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/handler.rs
 *
 *-------------------------------------------------------------------------
 */

//! Bridges decoded runtime requests to gateway request processing.

use std::marker::PhantomData;

use bytes::Bytes;
use nacelle::{
    core::{pipeline::Completed, NacelleBody, NacelleError},
    tcp::{
        SerialTcpHandler, SerialTcpOneWayContext, SerialTcpOneWayHandler, SerialTcpRequestContext,
        TcpHandlerCompletion,
    },
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::{
    context::ConnectionContext,
    postgres::PgDataClient,
    protocol::header::Header,
    runtime::v2::{
        body::{collect_body, BoundedResponseWriter},
        protocol::{gateway_max_frame_len, gateway_max_request_body_len, GatewayWireProtocol},
    },
    service::process_request_message,
};

pub(super) struct GatewayConnectionState {
    connection_context: ConnectionContext,
    shutdown_token: CancellationToken,
    response_chunk_size: usize,
}

impl GatewayConnectionState {
    /// Creates state scoped to one serial gateway connection.
    #[must_use]
    pub(super) const fn new(
        connection_context: ConnectionContext,
        shutdown_token: CancellationToken,
        response_chunk_size: usize,
    ) -> Self {
        Self {
            connection_context,
            shutdown_token,
            response_chunk_size,
        }
    }

    /// Returns whether the connection has authenticated.
    #[must_use]
    pub(super) fn is_authenticated(&self) -> bool {
        self.connection_context.auth_state.is_authenticated()
    }

    #[cfg(test)]
    /// Returns the gateway connection identifier used for request activity IDs.
    pub(super) const fn connection_id(&self) -> uuid::Uuid {
        self.connection_context.connection_id
    }

    fn should_close_for_shutdown(&self) -> bool {
        self.shutdown_token.is_cancelled()
            && !self
                .connection_context
                .dynamic_configuration()
                .send_shutdown_responses()
    }
}

#[derive(Debug)]
pub(super) struct GatewayRuntimeHandler<T> {
    _data_client: PhantomData<fn() -> T>,
}

impl<T> Clone for GatewayRuntimeHandler<T> {
    fn clone(&self) -> Self {
        Self {
            _data_client: PhantomData,
        }
    }
}

impl<T> GatewayRuntimeHandler<T> {
    /// Creates a required-response gateway handler.
    #[must_use]
    pub(super) const fn new() -> Self {
        Self {
            _data_client: PhantomData,
        }
    }
}

impl<T> SerialTcpHandler<GatewayWireProtocol> for GatewayRuntimeHandler<T>
where
    T: PgDataClient + 'static,
{
    async fn call<'connection>(
        &'connection self,
        mut context: SerialTcpRequestContext<'connection, GatewayWireProtocol>,
    ) -> std::result::Result<TcpHandlerCompletion<GatewayWireProtocol>, NacelleError> {
        if context.connection().state.should_close_for_shutdown() {
            return Err(NacelleError::ConnectionClosed);
        }
        if let Some(error) = context.request().head.decode_error() {
            return Err(NacelleError::protocol(error));
        }
        let header = context.request().head.header();
        let read_request_start = context.request().head.read_request_start();
        let body = std::mem::replace(&mut context.request_mut().body, NacelleBody::empty());
        let response_chunk_size = context.connection().state.response_chunk_size;
        let response = process_request::<T>(
            &mut context.connection_mut().state,
            header,
            body,
            read_request_start,
            response_chunk_size,
            gateway_max_frame_len(),
        )
        .await?;
        if response.is_empty() {
            return Err(NacelleError::InvalidFrame(
                "required-response gateway request produced no response",
            ));
        }
        context.respond(response).await
    }
}

impl<T> SerialTcpOneWayHandler<GatewayWireProtocol> for GatewayRuntimeHandler<T>
where
    T: PgDataClient + 'static,
{
    async fn call<'connection>(
        &'connection self,
        mut context: SerialTcpOneWayContext<'connection, GatewayWireProtocol>,
    ) -> std::result::Result<Completed, NacelleError> {
        if context.connection().state.should_close_for_shutdown() {
            return Err(NacelleError::ConnectionClosed);
        }
        if let Some(error) = context.request().head.decode_error() {
            return Err(NacelleError::protocol(error));
        }
        let header = context.request().head.header();
        let read_request_start = context.request().head.read_request_start();
        let body = std::mem::replace(&mut context.request_mut().body, NacelleBody::empty());
        let response_chunk_size = context.connection().state.response_chunk_size;
        if !process_request::<T>(
            &mut context.connection_mut().state,
            header,
            body,
            read_request_start,
            response_chunk_size,
            0,
        )
        .await?
        .is_empty()
        {
            return Err(NacelleError::InvalidFrame(
                "one-way gateway request produced a response",
            ));
        }
        Ok(context.complete())
    }
}

async fn process_request<T>(
    connection_state: &mut GatewayConnectionState,
    header: Header,
    body: NacelleBody,
    read_request_start: Instant,
    response_chunk_size: usize,
    max_response_bytes: usize,
) -> std::result::Result<Bytes, NacelleError>
where
    T: PgDataClient,
{
    let bytes = collect_body(body, gateway_max_request_body_len()).await?;
    let mut writer = BoundedResponseWriter::new(max_response_bytes, response_chunk_size)?;
    let connection_context = &mut connection_state.connection_context;
    let activity_uuid = connection_context.generate_request_activity_id(header.request_id());
    let mut activity_buf = [0u8; uuid::fmt::Hyphenated::LENGTH];
    let activity_id = activity_uuid.hyphenated().encode_lower(&mut activity_buf);
    process_request_message::<T, _>(
        connection_context,
        header,
        bytes,
        read_request_start,
        activity_id,
        &mut writer,
    )
    .await
    .map_err(NacelleError::handler)?;
    writer.into_response()
}
