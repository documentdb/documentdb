/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/verbose_latency.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    context::ConnectionContext,
    requests::{request_tracker::RequestTracker, Request, RequestIntervalKind},
    responses::CommandError,
    telemetry::{event_id::EventId, utils},
};

/// Returns whether verbose latency logging should be emitted for this request.
fn should_log_verbose_latency(
    connection_context: &ConnectionContext,
    request_tracker: &RequestTracker,
) -> bool {
    if connection_context
        .dynamic_configuration()
        .enable_verbose_logging_in_gateway()
    {
        return true;
    }

    let slow_query_threshold_ms = connection_context
        .dynamic_configuration()
        .slow_query_log_interval_ms();
    if slow_query_threshold_ms > 0 {
        let duration_ms =
            request_tracker.get_interval_elapsed_time_ms(RequestIntervalKind::HandleMessage);
        return duration_ms >= i64::from(slow_query_threshold_ms);
    }

    false
}

/// Logs verbose latency information for a request if verbose logging is enabled
/// or the request exceeded the slow query threshold.
#[expect(
    clippy::too_many_arguments,
    reason = "verbose latency logging requires all request context dimensions"
)]
pub fn try_log_verbose_latency(
    connection_context: &ConnectionContext,
    request: Option<&Request<'_>>,
    collection: &str,
    request_tracker: &RequestTracker,
    activity_id: &str,
    error: Option<&CommandError>,
    request_length: i64,
    response_length: i64,
) {
    if !should_log_verbose_latency(connection_context, request_tracker) {
        return;
    }

    let database_name = request.and_then(|r| r.db().ok()).unwrap_or_default();
    let request_type = request
        .map(|r| r.request_type().to_string())
        .unwrap_or_default();

    let status_code = utils::get_status_code_u16(error);
    let error_code = utils::get_error_code_i32(error);

    tracing::info!(
        activity_id = activity_id,
        event_id = EventId::RequestTrace.code(),
        read_request = request_tracker.get_interval_elapsed_time(RequestIntervalKind::ReadRequest),
        handle_message = request_tracker.get_interval_elapsed_time(RequestIntervalKind::HandleMessage),
        format_request = request_tracker.get_interval_elapsed_time(RequestIntervalKind::FormatRequest),
        handle_request = request_tracker.get_interval_elapsed_time(RequestIntervalKind::HandleRequest),
        process_request = request_tracker.get_interval_elapsed_time(RequestIntervalKind::ProcessRequest),
        postgres_begin_transaction = request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresBeginTransaction),
        postgres_set_statement_timeout = request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresSetStatementTimeout),
        postgres_commit_transaction = request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresCommitTransaction),
        open_backend_connection = request_tracker.get_interval_elapsed_time(RequestIntervalKind::OpenBackendConnection),
        write_response = request_tracker.get_interval_elapsed_time(RequestIntervalKind::WriteResponse),
        address = %connection_context.ip_address,
        transport_protocol = %connection_context.transport_protocol(),
        database_name = database_name,
        collection_name = collection,
        operation_name = request_type,
        status_code = status_code,
        sub_status_code = 0,
        error_code = error_code,
        request_length = request_length,
        response_length = response_length,
        "Latency for Mongo Request with interval timings (ns)."
    );
}
