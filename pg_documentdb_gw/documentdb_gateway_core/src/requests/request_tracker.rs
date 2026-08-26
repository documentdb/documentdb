/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/request_tracker.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

use tokio::time::Instant;

use crate::telemetry::utils;

#[derive(Debug)]
pub enum RequestIntervalKind {
    /// Time spent reading stream from request body.
    ReadRequest,

    /// Interval kind for the overall request processing duration, which includes `FormatRequest`, and `HandleRequest` via backend.
    /// `ReadRequest` and `WriteResponse` are not part of `HandleMessage`.
    HandleMessage,

    /// Time spent formatting and parsing the incoming request.
    FormatRequest,

    /// Time spent handling the request, which includes `ProcessRequest` and, if applicable,
    /// `PostgresBeginTransaction`, `PostgresSetStatementTimeout`, and `PostgresCommitTransaction`.
    HandleRequest,

    /// Time spent in network transport and Postgres processing.
    ProcessRequest,

    /// Time spent beginning a Postgres transaction.
    PostgresBeginTransaction,

    /// Time spent setting statement timeout parameters in Postgres.
    PostgresSetStatementTimeout,

    /// Time spent committing a Postgres transaction.
    PostgresCommitTransaction,

    /// Time spent acquiring a connection from the Postgres connection pool.
    OpenBackendConnection,

    /// Time spent writing the response to the stream.
    WriteResponse,

    /// Special value used to define the size of the metrics array.
    MaxUnused,
}

#[derive(Debug)]
pub struct RequestTracker {
    pub request_interval_metrics_array: [AtomicU64; RequestIntervalKind::MaxUnused as usize],

    /// Backend cursor id opened, continued, or targeted by this request, when the
    /// request involves a single cursor (find/aggregate first page that spans
    /// multiple batches, getMore, or a single-cursor killCursors). A value of 0
    /// means no cursor is associated with the request, matching the wire-protocol
    /// sentinel for "no more cursor".
    cursor_id: AtomicI64,
}

impl Default for RequestTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl RequestTracker {
    #[must_use]
    pub fn new() -> Self {
        Self {
            request_interval_metrics_array: std::array::from_fn(|_| AtomicU64::new(0)),
            cursor_id: AtomicI64::new(0),
        }
    }

    #[expect(clippy::cast_possible_truncation, reason = "nanoseconds fit in u64")]
    pub fn record_duration(&self, interval: RequestIntervalKind, start_time: Instant) {
        let elapsed = start_time.elapsed();
        self.request_interval_metrics_array[interval as usize]
            .fetch_add(elapsed.as_nanos() as u64, Ordering::Relaxed);
    }

    pub fn get_interval_elapsed_time(&self, interval: RequestIntervalKind) -> u64 {
        self.request_interval_metrics_array[interval as usize].load(Ordering::Relaxed)
    }

    pub fn get_interval_elapsed_time_ms(&self, interval: RequestIntervalKind) -> u64 {
        utils::ns_to_ms(self.get_interval_elapsed_time(interval))
    }

    /// Records the backend cursor id associated with this request for diagnostics.
    pub fn set_cursor_id(&self, cursor_id: i64) {
        self.cursor_id.store(cursor_id, Ordering::Relaxed);
    }

    /// Returns the backend cursor id associated with this request, or `None` when
    /// the request does not involve a cursor.
    pub fn cursor_id(&self) -> Option<i64> {
        match self.cursor_id.load(Ordering::Relaxed) {
            0 => None,
            id => Some(id),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_id_defaults_to_none() {
        let tracker = RequestTracker::new();
        assert_eq!(tracker.cursor_id(), None);
    }

    #[test]
    fn cursor_id_round_trips_after_set() {
        let tracker = RequestTracker::new();
        tracker.set_cursor_id(42);
        assert_eq!(tracker.cursor_id(), Some(42));
    }

    #[test]
    fn cursor_id_zero_is_treated_as_none() {
        let tracker = RequestTracker::new();
        tracker.set_cursor_id(42);
        tracker.set_cursor_id(0);
        assert_eq!(tracker.cursor_id(), None);
    }
}
