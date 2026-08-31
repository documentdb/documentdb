/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/connection.rs
 *
 *-------------------------------------------------------------------------
 */

//! Owns connection admission, serial serving, and bounded writer shutdown.

use std::{net::IpAddr, sync::Arc, time::Duration};

use nacelle::{
    core::{
        NacelleConnectionMeta, NacelleError, NacelleLimits, NacelleRequestMetricsConfig,
        NacelleRuntimeState, NacelleTelemetry, NacelleTransport, TrackedPermit,
    },
    tcp::{
        connection::serve_serial_stream_without_connection_limit, NacelleTcpConfig,
        NacelleTcpLimits, ResponseWritePolicy, TcpRequestBodyMode,
    },
};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::ServiceContext,
    postgres::PgDataClient,
    runtime::v2::{
        handler::GatewayRuntimeHandler,
        protocol::{gateway_max_frame_len, GatewayWireProtocol},
    },
    telemetry::TelemetryProvider,
};

const CONNECTION_WRITER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(15);

pub(super) struct GatewayRuntime<T> {
    protocol: Arc<GatewayWireProtocol>,
    handler: Arc<GatewayRuntimeHandler<T>>,
    config: NacelleTcpConfig,
    telemetry: NacelleTelemetry,
    runtime_state: NacelleRuntimeState,
    service_context: ServiceContext,
}

impl<T> Clone for GatewayRuntime<T> {
    fn clone(&self) -> Self {
        Self {
            protocol: Arc::clone(&self.protocol),
            handler: Arc::clone(&self.handler),
            config: self.config.clone(),
            telemetry: self.telemetry.clone(),
            runtime_state: self.runtime_state.clone(),
            service_context: self.service_context.clone(),
        }
    }
}

impl<T> GatewayRuntime<T>
where
    T: PgDataClient + 'static,
{
    /// Creates the shared runtime used by all gateway listeners.
    #[must_use]
    pub(super) fn new(
        service_context: ServiceContext,
        telemetry_provider: Option<Box<dyn TelemetryProvider>>,
        shutdown_token: CancellationToken,
    ) -> Self {
        let runtime_state = NacelleRuntimeState::new(gateway_limits(&service_context));
        let telemetry = gateway_tcp_telemetry(&service_context);
        telemetry.register_runtime_state(runtime_state.clone());
        let config = gateway_tcp_config(&service_context);
        Self {
            protocol: Arc::new(GatewayWireProtocol::new(
                service_context.clone(),
                telemetry_provider,
                shutdown_token,
                config.response_buffer_capacity,
            )),
            handler: Arc::new(GatewayRuntimeHandler::new()),
            config,
            telemetry,
            runtime_state,
            service_context,
        }
    }

    /// Serves one admitted connection and shuts down its writer after serving ends.
    ///
    /// # Errors
    ///
    /// Returns the terminal runtime error produced while serving the connection.
    pub(super) async fn serve<IO>(
        &self,
        mut io: IO,
        connection: NacelleConnectionMeta,
        connection_id: Uuid,
    ) -> std::result::Result<(), NacelleError>
    where
        IO: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        serve_serial_stream_without_connection_limit(
            &mut io,
            Arc::new(self.protocol.for_connection(connection_id)),
            Arc::clone(&self.handler),
            Arc::clone(&self.handler),
            self.config.clone(),
            self.telemetry.clone(),
            self.runtime_state.clone(),
            gateway_tcp_limits(&self.service_context),
            connection,
        )
        .await
    }

    /// Acquires a tracked connection permit for the peer or local transport.
    ///
    /// # Errors
    ///
    /// Returns a resource-limit error when connection admission is denied.
    pub(super) fn acquire_connection(
        &self,
        peer_ip: Option<IpAddr>,
    ) -> std::result::Result<TrackedPermit, NacelleError> {
        if let Some(peer_ip) = peer_ip {
            self.runtime_state.acquire_connection_for_peer(peer_ip)
        } else {
            self.runtime_state.acquire_connection_tracked()
        }
    }

    /// Records that connection admission rejected a peer.
    pub(super) fn record_connection_rejection(
        &self,
        transport: &'static str,
        error: &NacelleError,
    ) {
        let reason = match error {
            NacelleError::ResourceLimit(reason) => reason.as_str(),
            _ => "admission",
        };
        self.telemetry
            .connection_rejected(NacelleTransport::new(transport), reason);
    }

    /// Returns the gateway service context used by this runtime.
    #[must_use]
    pub(super) const fn service_context(&self) -> &ServiceContext {
        &self.service_context
    }
}

fn gateway_tcp_config(service_context: &ServiceContext) -> NacelleTcpConfig {
    let setup_configuration = service_context.setup_configuration();
    NacelleTcpConfig::default()
        .with_read_buffer_capacity(setup_configuration.stream_read_buffer_size())
        .with_response_buffer_capacity(setup_configuration.stream_write_buffer_size())
        .with_max_frame_len(gateway_max_frame_len())
        .with_request_body_mode(TcpRequestBodyMode::Streaming)
        .with_response_write_policy(ResponseWritePolicy::Immediate)
}

fn gateway_limits(service_context: &ServiceContext) -> NacelleLimits {
    let max_frame_len = gateway_max_frame_len();
    let max_connections = service_context.dynamic_configuration().max_connections();
    NacelleLimits::default()
        .with_max_connections(max_connections)
        .with_max_in_flight_requests(max_connections)
        .with_max_request_body_bytes(max_frame_len)
        .with_max_response_body_bytes(max_frame_len)
}

fn gateway_tcp_limits(service_context: &ServiceContext) -> NacelleTcpLimits {
    NacelleTcpLimits::default()
        .with_shutdown_timeout(CONNECTION_WRITER_SHUTDOWN_TIMEOUT)
        .with_idle_timeout(Duration::from_secs(
            service_context
                .dynamic_configuration()
                .socket_connection_idle_timeout_sec(),
        ))
        .without_read_timeout()
        .without_write_timeout()
}

fn gateway_tcp_telemetry(service_context: &ServiceContext) -> NacelleTelemetry {
    NacelleTelemetry::new().with_request_metrics(gateway_request_metrics(
        service_context.request_metrics_enabled(),
    ))
}

/// Returns the request metrics controlled by gateway telemetry configuration.
pub(super) const fn gateway_request_metrics(enabled: bool) -> NacelleRequestMetricsConfig {
    NacelleRequestMetricsConfig {
        started: enabled,
        completed: enabled,
        in_flight: enabled,
        duration_ms: false,
        byte_counts: enabled,
    }
}
