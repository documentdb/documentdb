/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/requests/request_tracker.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicI64, Ordering};
use tokio::time::Instant;

#[derive(Debug)]
pub enum RequestIntervalKind {
    /// Interval kind for the overall request processing duration, which includes BufferRead, FormatRequest, and HandleRequest via backend.
    HandleMessage,

    /// Time spent reading stream from request body.
    BufferRead,

    /// Time spent formatting and parsing the incoming request.
    FormatRequest,

    /// Time spent handling the request, which includes ProcessRequest and, if applicable,
    /// PostgresBeginTransaction, PostgresSetStatementTimeout, and PostgresCommitTransaction.
    HandleRequest,

    /// Time spent in network transport and Postgres processing.
    ProcessRequest,

    /// Time spent beginning a Postgres transaction.
    PostgresBeginTransaction,

    /// Time spent setting statement timeout parameters in Postgres.
    PostgresSetStatementTimeout,

    /// Time spent committing a Postgres transaction.
    PostgresCommitTransaction,

    /// Special value used to define the size of the metrics array.
    MaxUnused,
}

#[derive(Debug)]
pub struct RequestTracker {
    pub request_interval_metrics_array: [AtomicI64; RequestIntervalKind::MaxUnused as usize],
}

impl Default for RequestTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl RequestTracker {
    pub fn new() -> Self {
        RequestTracker {
            request_interval_metrics_array: std::array::from_fn(|_| AtomicI64::new(0)),
        }
    }

    pub fn record_duration(&self, interval: RequestIntervalKind, start_time: Instant) {
        let elapsed = start_time.elapsed();
        self.request_interval_metrics_array[interval as usize]
            .fetch_add(elapsed.as_nanos() as i64, Ordering::Relaxed);
    }

    pub fn get_interval_elapsed_time(&self, interval: RequestIntervalKind) -> i64 {
        self.request_interval_metrics_array[interval as usize].load(Ordering::Relaxed)
    }
}
