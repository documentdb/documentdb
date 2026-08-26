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

    metrics::counter!(metric_names::DB_CLIENT_OPERATIONS, base_labels.clone()).increment(1);
    metrics::histogram!(
        metric_names::DB_CLIENT_OPERATION_DURATION,
        base_labels.clone()
    )
    .record(duration_to_secs(duration_ns));

    metrics::counter!(
        metric_names::DB_CLIENT_REQUEST_SIZE_TOTAL,
        base_labels.clone()
    )
    .increment(u64::from(header.message_length().max(0).cast_unsigned()));

    let response_size_bytes = match &response {
        Either::Left(resp) => resp
            .as_raw_document()
            .map_or(0, |doc| doc.as_bytes().len() as u64),
        Either::Right((_, size)) => *size as u64,
    };
    metrics::counter!(
        metric_names::DB_CLIENT_RESPONSE_SIZE_TOTAL,
        base_labels.clone()
    )
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
            metrics::histogram!(
                metric_names::DB_CLIENT_OPERATION_DURATION,
                phase_labels.clone()
            )
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
                    metrics::counter!(metric_names::DB_CLIENT_DOCUMENTS_RETURNED, labels.to_vec())
                        .increment(batch_len);
                }
            }
        }
        RequestType::Insert => {
            // Insert response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics::counter!(metric_names::DB_CLIENT_DOCUMENTS_INSERTED, labels.to_vec())
                    .increment(u64::from(n.max(0).cast_unsigned()));
            }
        }
        RequestType::Update | RequestType::FindAndModify => {
            // Update response: { nModified: <count> }
            if let Ok(n) = doc.get_i32("nModified") {
                metrics::counter!(metric_names::DB_CLIENT_DOCUMENTS_UPDATED, labels.to_vec())
                    .increment(u64::from(n.max(0).cast_unsigned()));
            }
        }
        RequestType::Delete => {
            // Delete response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics::counter!(metric_names::DB_CLIENT_DOCUMENTS_DELETED, labels.to_vec())
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
