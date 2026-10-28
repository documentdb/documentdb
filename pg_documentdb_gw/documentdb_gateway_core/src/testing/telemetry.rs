/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/telemetry.rs
 *
 * Shared telemetry test doubles for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, MutexGuard,
    },
};

use either::Either;
use metrics::{
    Counter, CounterFn, Gauge, GaugeFn, Histogram, Key, KeyName, Metadata, Recorder, SharedString,
    Unit,
};

use crate::{
    context::ConnectionContext,
    error::DocumentDBError,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, RequestObservation, RequestType},
    responses::Response,
    telemetry::TelemetryProvider,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedTelemetryEvent {
    activity_id: String,
    collection: String,
    user_agent: String,
    request_type: Option<RequestType>,
    is_error: bool,
    error_code_name: Option<String>,
    sub_status_code: i32,
}

impl RecordedTelemetryEvent {
    pub fn activity_id(&self) -> &str {
        &self.activity_id
    }

    pub fn collection(&self) -> &str {
        &self.collection
    }

    pub fn user_agent(&self) -> &str {
        &self.user_agent
    }

    pub fn request_type(&self) -> Option<RequestType> {
        self.request_type
    }

    pub fn is_error(&self) -> bool {
        self.is_error
    }

    pub fn error_code_name(&self) -> Option<&str> {
        self.error_code_name.as_deref()
    }

    pub fn sub_status_code(&self) -> i32 {
        self.sub_status_code
    }
}

#[derive(Clone, Debug, Default)]
pub struct RecordingTelemetryProvider {
    events: Arc<Mutex<Vec<RecordedTelemetryEvent>>>,
}

impl RecordingTelemetryProvider {
    pub fn events(&self) -> Vec<RecordedTelemetryEvent> {
        self.events
            .lock()
            .expect("telemetry events lock should not be poisoned")
            .clone()
    }
}

impl TelemetryProvider for RecordingTelemetryProvider {
    fn emit_request_event(
        &self,
        _: &ConnectionContext,
        _: &Header,
        request: Option<RequestObservation<'_, '_>>,
        response: Either<&Response, (&DocumentDBError, usize)>,
        collection: &str,
        _: &RequestTracker,
        activity_id: &str,
        user_agent: &str,
    ) {
        let (is_error, error_code_name, sub_status_code) = match response {
            Either::Left(_) => (false, None, 0),
            Either::Right((error, _)) => (
                true,
                Some(error.error_code().to_string()),
                error.sub_status_code().unwrap_or(0),
            ),
        };

        self.events
            .lock()
            .expect("telemetry events lock should not be poisoned")
            .push(RecordedTelemetryEvent {
                activity_id: activity_id.to_owned(),
                collection: collection.to_owned(),
                user_agent: user_agent.to_owned(),
                request_type: request.map(RequestObservation::request_type),
                is_error,
                error_code_name,
                sub_status_code,
            });
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetricKind {
    Counter,
    Gauge,
    Histogram,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetricDescription {
    kind: MetricKind,
    unit: Option<Unit>,
    description: String,
}

impl MetricDescription {
    pub const fn kind(&self) -> MetricKind {
        self.kind
    }

    pub const fn unit(&self) -> Option<Unit> {
        self.unit
    }

    pub fn description(&self) -> &str {
        &self.description
    }
}

type SeriesKey = (String, Vec<(String, String)>);

#[derive(Debug, Default)]
struct RecordedCounter(AtomicU64);

impl CounterFn for RecordedCounter {
    fn increment(&self, value: u64) {
        self.0.fetch_add(value, Ordering::Relaxed);
    }

    fn absolute(&self, value: u64) {
        self.0.fetch_max(value, Ordering::Relaxed);
    }
}

/// Last gauge value, stored as `f64` bits.
#[derive(Debug, Default)]
struct RecordedGauge(AtomicU64);

impl RecordedGauge {
    fn value(&self) -> f64 {
        f64::from_bits(self.0.load(Ordering::Relaxed))
    }

    fn update(&self, apply: impl Fn(f64) -> f64) {
        let _ = self
            .0
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |bits| {
                Some(apply(f64::from_bits(bits)).to_bits())
            });
    }
}

impl GaugeFn for RecordedGauge {
    fn increment(&self, value: f64) {
        self.update(|current| current + value);
    }

    fn decrement(&self, value: f64) {
        self.update(|current| current - value);
    }

    fn set(&self, value: f64) {
        self.0.store(value.to_bits(), Ordering::Relaxed);
    }
}

/// In-memory [`Recorder`] for asserting on metric metadata, counter totals,
/// and last gauge values.
///
/// Install it with [`metrics::with_local_recorder`] or
/// [`metrics::set_default_local_recorder`]. Handles registered while it is
/// installed keep reporting to it after the recorder is uninstalled.
/// Histogram samples are discarded.
#[derive(Debug, Default)]
pub struct RecordingMetricsRecorder {
    descriptions: Mutex<HashMap<String, MetricDescription>>,
    counters: Mutex<HashMap<SeriesKey, Arc<RecordedCounter>>>,
    gauges: Mutex<HashMap<SeriesKey, Arc<RecordedGauge>>>,
}

impl RecordingMetricsRecorder {
    pub fn description(&self, name: &str) -> Option<MetricDescription> {
        lock(&self.descriptions).get(name).cloned()
    }

    /// Returns the total of the counter series with exactly these labels.
    pub fn counter(&self, name: &str, labels: &[(&str, &str)]) -> Option<u64> {
        lock(&self.counters)
            .get(&expected_series(name, labels))
            .map(|counter| counter.0.load(Ordering::Relaxed))
    }

    /// Returns the last value of the gauge series with exactly these labels.
    pub fn gauge(&self, name: &str, labels: &[(&str, &str)]) -> Option<f64> {
        lock(&self.gauges)
            .get(&expected_series(name, labels))
            .map(|gauge| gauge.value())
    }

    /// Returns the number of registered counter and gauge series for `name`.
    pub fn series_count(&self, name: &str) -> usize {
        let counters = lock(&self.counters)
            .keys()
            .filter(|(series_name, _)| series_name == name)
            .count();
        let gauges = lock(&self.gauges)
            .keys()
            .filter(|(series_name, _)| series_name == name)
            .count();
        counters + gauges
    }

    fn describe(&self, key: &KeyName, kind: MetricKind, unit: Option<Unit>, text: &SharedString) {
        lock(&self.descriptions).insert(
            key.as_str().to_owned(),
            MetricDescription {
                kind,
                unit,
                description: text.to_string(),
            },
        );
    }
}

impl Recorder for RecordingMetricsRecorder {
    fn describe_counter(&self, key: KeyName, unit: Option<Unit>, description: SharedString) {
        self.describe(&key, MetricKind::Counter, unit, &description);
    }

    fn describe_gauge(&self, key: KeyName, unit: Option<Unit>, description: SharedString) {
        self.describe(&key, MetricKind::Gauge, unit, &description);
    }

    fn describe_histogram(&self, key: KeyName, unit: Option<Unit>, description: SharedString) {
        self.describe(&key, MetricKind::Histogram, unit, &description);
    }

    fn register_counter(&self, key: &Key, _metadata: &Metadata<'_>) -> Counter {
        let counter = Arc::clone(
            lock(&self.counters)
                .entry(registered_series(key))
                .or_default(),
        );
        Counter::from_arc(counter)
    }

    fn register_gauge(&self, key: &Key, _metadata: &Metadata<'_>) -> Gauge {
        let gauge = Arc::clone(
            lock(&self.gauges)
                .entry(registered_series(key))
                .or_default(),
        );
        Gauge::from_arc(gauge)
    }

    fn register_histogram(&self, _key: &Key, _metadata: &Metadata<'_>) -> Histogram {
        Histogram::noop()
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .expect("metrics recorder lock should not be poisoned")
}

fn registered_series(key: &Key) -> SeriesKey {
    series(
        key.name(),
        key.labels()
            .map(|label| (label.key().to_owned(), label.value().to_owned())),
    )
}

fn expected_series(name: &str, labels: &[(&str, &str)]) -> SeriesKey {
    series(
        name,
        labels
            .iter()
            .map(|&(key, value)| (key.to_owned(), value.to_owned())),
    )
}

fn series(name: &str, labels: impl Iterator<Item = (String, String)>) -> SeriesKey {
    let mut labels: Vec<_> = labels.collect();
    labels.sort_unstable();
    (name.to_owned(), labels)
}
