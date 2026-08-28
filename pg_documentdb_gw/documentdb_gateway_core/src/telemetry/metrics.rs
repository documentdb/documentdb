/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/metrics.rs
 *
 *-------------------------------------------------------------------------
 */

use std::time::Duration;

use either::Either;

use crate::{
    error::DocumentDBError,
    protocol::header::Header,
    requests::{
        request_tracker::RequestTracker, RequestIntervalKind, RequestObservation, RequestType,
    },
    responses::Response,
    telemetry::consts::{labels, metric_names},
};

// ============================================================================
// Gateway Metrics
// ============================================================================

/// Registers metadata for the gateway's provider-neutral metric instruments.
///
/// Call this after installing the process-wide [`metrics::Recorder`] so each
/// exporter can receive the shared instrument kinds, units, and descriptions.
pub fn describe_metrics() {
    metrics::describe_histogram!(
        metric_names::OPERATION_DURATION,
        metrics::Unit::Seconds,
        "Duration of gateway request handling and its recorded backend phases"
    );
    metrics::describe_counter!(
        metric_names::OPERATIONS,
        metrics::Unit::Count,
        "Gateway operations completed, including failed operations"
    );
    metrics::describe_counter!(
        metric_names::REQUEST_SIZE_TOTAL,
        metrics::Unit::Bytes,
        "Cumulative size of request messages received by the gateway"
    );
    metrics::describe_counter!(
        metric_names::RESPONSE_SIZE_TOTAL,
        metrics::Unit::Bytes,
        "Cumulative size of response messages produced by the gateway"
    );
    metrics::describe_counter!(
        metric_names::DOCUMENTS_RETURNED,
        metrics::Unit::Count,
        "Documents returned by successful find, aggregate, and get-more operations"
    );
    metrics::describe_counter!(
        metric_names::DOCUMENTS_INSERTED,
        metrics::Unit::Count,
        "Documents reported as inserted by successful insert operations"
    );
    metrics::describe_counter!(
        metric_names::DOCUMENTS_UPDATED,
        metrics::Unit::Count,
        "Documents reported as modified by successful update and find-and-modify operations"
    );
    metrics::describe_counter!(
        metric_names::DOCUMENTS_DELETED,
        metrics::Unit::Count,
        "Documents reported as deleted by successful delete operations"
    );
    metrics::describe_gauge!(
        metric_names::SESSION_ACTIVE,
        metrics::Unit::Count,
        "Logical sessions currently tracked by the gateway"
    );
    metrics::describe_counter!(
        metric_names::SESSION_OPENED,
        metrics::Unit::Count,
        "Logical sessions opened by the gateway"
    );
    metrics::describe_counter!(
        metric_names::SESSION_CLOSED,
        metrics::Unit::Count,
        "Logical sessions closed normally by the gateway"
    );
    metrics::describe_counter!(
        metric_names::SESSION_EXPIRED,
        metrics::Unit::Count,
        "Logical sessions removed after their lifetime expired"
    );
    metrics::describe_gauge!(
        metric_names::TRANSACTION_ACTIVE,
        metrics::Unit::Count,
        "Transactions currently held in the gateway transaction store"
    );
    metrics::describe_counter!(
        metric_names::TRANSACTION_STARTED,
        metrics::Unit::Count,
        "Transactions successfully started and inserted into the transaction store"
    );
    metrics::describe_counter!(
        metric_names::TRANSACTION_ENDED,
        metrics::Unit::Count,
        "Transactions removed after commit, abort, or expiration"
    );
    metrics::describe_gauge!(
        metric_names::CURSOR_ACTIVE,
        metrics::Unit::Count,
        "Cursors currently held in the gateway cursor store"
    );
    metrics::describe_counter!(
        metric_names::CURSOR_OPENED,
        metrics::Unit::Count,
        "Logical cursors opened from an initial query continuation"
    );
    metrics::describe_counter!(
        metric_names::CURSOR_ENDED,
        metrics::Unit::Count,
        "Logical cursors ended by exhaustion, explicit kill, invalidation, or expiration"
    );
    metrics::describe_histogram!(
        metric_names::GATEWAY_STARTUP_DELAY_MS,
        metrics::Unit::Milliseconds,
        "Time until the gateway is ready to accept connections"
    );
    metrics::describe_counter!(
        metric_names::GATEWAY_STARTS,
        metrics::Unit::Count,
        "Count of gateway readiness events"
    );
}

/// Records request-level metrics directly in the request handling path.
///
/// Called unconditionally for every request. When no global [`metrics::Recorder`]
/// is installed, all metric operations are no-ops.
///
/// Aggregation (averages, percentiles) is delegated to the collector.
pub fn record_gateway_metrics(
    header: &Header,
    request: Option<RequestObservation<'_, '_>>,
    response: Either<&Response, (&DocumentDBError, usize)>,
    collection: &str,
    request_tracker: &RequestTracker,
) {
    let operation = request.map_or_else(|| "unknown".to_owned(), |r| r.request_type().to_string());

    let db_name = request
        .and_then(RequestObservation::db)
        .unwrap_or("unknown");

    let duration_to_secs = |ns: u64| -> f64 { Duration::from_nanos(ns).as_secs_f64() };

    let duration_ns = request_tracker.get_interval_elapsed_time(RequestIntervalKind::HandleRequest);

    let mut base_labels = vec![
        metrics::Label::new(labels::DB_SYSTEM_NAME, "documentdb"),
        metrics::Label::new(labels::DB_OPERATION_NAME, operation),
        metrics::Label::new(labels::DB_COLLECTION_NAME, collection.to_owned()),
        metrics::Label::new(labels::DB_NAMESPACE, db_name.to_owned()),
    ];
    if let Either::Right((err, _)) = &response {
        base_labels.push(metrics::Label::new(
            labels::ERROR_TYPE,
            err.error_code().to_string(),
        ));
    }

    metrics::counter!(metric_names::OPERATIONS, base_labels.clone()).increment(1);
    metrics::histogram!(metric_names::OPERATION_DURATION, base_labels.clone())
        .record(duration_to_secs(duration_ns));

    metrics::counter!(metric_names::REQUEST_SIZE_TOTAL, base_labels.clone())
        .increment(u64::from(header.message_length().max(0).cast_unsigned()));

    let response_size_bytes = match &response {
        Either::Left(resp) => resp
            .as_raw_document()
            .map_or(0, |doc| doc.as_bytes().len() as u64),
        Either::Right((_, size)) => *size as u64,
    };
    metrics::counter!(metric_names::RESPONSE_SIZE_TOTAL, base_labels.clone())
        .increment(response_size_bytes);

    // Record document throughput counters based on operation type
    if let Some(req) = request {
        if let Either::Left(resp) = &response {
            record_document_counts(req.request_type(), resp, &base_labels);
        }
    }

    // Record PostgreSQL phase breakdown (duration totals).
    let mut phase_labels = Vec::with_capacity(base_labels.len() + 1);

    let mut record_phase = |phase: &'static str, ns: u64| {
        if ns > 0 {
            phase_labels.clear();
            phase_labels.extend_from_slice(&base_labels);
            phase_labels.push(metrics::Label::new(labels::DB_OPERATION_PHASE, phase));
            metrics::histogram!(metric_names::OPERATION_DURATION, phase_labels.clone())
                .record(duration_to_secs(ns));
        }
    };

    record_phase(
        "postgres_begin_transaction",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresBeginTransaction),
    );
    record_phase(
        "postgres_execution",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::ProcessRequest),
    );
    record_phase(
        "postgres_commit",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresCommitTransaction),
    );
}

/// Extract document counts from the response based on operation type.
fn record_document_counts(
    request_type: RequestType,
    response: &Response,
    labels: &[metrics::Label],
) {
    let Ok(doc) = response.as_raw_document() else {
        return;
    };

    match request_type {
        RequestType::Find | RequestType::Aggregate | RequestType::GetMore => {
            // Cursor responses: { cursor: { firstBatch/nextBatch: [...] } }
            if let Ok(cursor) = doc.get_document("cursor") {
                let batch_len = cursor
                    .get_array("firstBatch")
                    .or_else(|_| cursor.get_array("nextBatch"))
                    .map_or(0, |arr| arr.into_iter().count() as u64);
                if batch_len > 0 {
                    metrics::counter!(metric_names::DOCUMENTS_RETURNED, labels.to_vec())
                        .increment(batch_len);
                }
            }
        }
        RequestType::Insert => {
            // Insert response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics::counter!(metric_names::DOCUMENTS_INSERTED, labels.to_vec())
                    .increment(u64::from(n.max(0).cast_unsigned()));
            }
        }
        RequestType::Update | RequestType::FindAndModify => {
            // Update response: { nModified: <count> }
            if let Ok(n) = doc.get_i32("nModified") {
                metrics::counter!(metric_names::DOCUMENTS_UPDATED, labels.to_vec())
                    .increment(u64::from(n.max(0).cast_unsigned()));
            }
        }
        RequestType::Delete => {
            // Delete response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics::counter!(metric_names::DOCUMENTS_DELETED, labels.to_vec())
                    .increment(u64::from(n.max(0).cast_unsigned()));
            }
        }
        _ => {}
    }
}

// ============================================================================
// Startup Metrics (recorded once per process start)
// ============================================================================

/// Records the gateway startup metrics once the gateway is ready to accept
/// connections.
///
/// Records the elapsed startup `duration` to the `gateway_startup_delay_ms`
/// histogram (in milliseconds) and increments the `gateway.starts` counter by
/// one.
///
/// Called once per process start. When no global [`metrics::Recorder`] is
/// installed, both metric operations are no-ops.
pub fn record_startup_metrics(duration: Duration) {
    metrics::histogram!(metric_names::GATEWAY_STARTUP_DELAY_MS)
        .record(duration.as_secs_f64() * 1000.0);
    metrics::counter!(metric_names::GATEWAY_STARTS).increment(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_record_startup_metrics_callable_without_provider() {
        super::record_startup_metrics(Duration::from_millis(42));
    }
}
