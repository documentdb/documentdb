/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_otel/src/lib.rs
 *
 *-------------------------------------------------------------------------
 */

pub(crate) mod config;
mod consts;

use std::{
    borrow::Cow,
    collections::HashMap,
    time::{Duration, SystemTime},
};

#[cfg(feature = "postgres-sql-commenter")]
use documentdb_gateway_core::telemetry::sql_commenter::{
    install_sql_commenter_hook, SqlCommenterHook,
};
use documentdb_gateway_core::{
    error::{DocumentDBError, Result},
    telemetry::{
        consts::metric_names,
        context_propagation::{install_trace_context_bridge, TraceContextBridge},
        TelemetrySettings,
    },
};
use metrics_exporter_opentelemetry::Recorder;
use opentelemetry::{
    global,
    trace::{
        Span as OpenTelemetrySpan, SpanBuilder, SpanContext, SpanId, SpanKind, Status,
        TraceContextExt, TraceFlags, TraceId, TraceState, Tracer, TracerProvider as _,
    },
    Context, KeyValue,
};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    metrics::{PeriodicReader, SdkMeterProvider, Temporality},
    propagation::TraceContextPropagator,
    trace::{RandomIdGenerator, Sampler, SdkTracer, SdkTracerProvider},
    Resource,
};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::{
    config::{MetricsConfig, TelemetryConfig, TracingConfig},
    consts::{instrumentation, resource_attributes, span_fields},
};

/// Owns the OpenTelemetry providers used by the gateway process.
#[derive(Debug)]
pub struct TelemetryManager {
    meter_provider: Option<SdkMeterProvider>,
    tracer_provider: Option<SdkTracerProvider>,
    settings: TelemetrySettings,
}

impl TelemetryManager {
    /// Initializes enabled OTLP signals and installs their process-wide bridges.
    ///
    /// # Errors
    ///
    /// Returns an error for reserved resource attributes, exporter construction
    /// failures, or failure to install the global metrics recorder.
    pub fn init_telemetry(
        options: Option<&serde_json::Value>,
        attributes: Option<HashMap<String, String>>,
    ) -> Result<Self> {
        let config = TelemetryConfig::new(options)?;
        validate_attributes(attributes.as_ref())?;

        if !config.any_signal_enabled() {
            return Ok(Self {
                meter_provider: None,
                tracer_provider: None,
                settings: config.settings(),
            });
        }

        let resource = create_resource(&config, attributes);
        let metrics = create_metrics_provider(config.metrics(), resource.clone())?;
        let tracer_provider = create_tracer_provider(config.tracing(), resource)?;

        let meter_provider = if let Some((provider, recorder)) = metrics {
            metrics::set_global_recorder(recorder).map_err(|error| {
                DocumentDBError::internal_error(format!(
                    "Failed to install global metrics recorder: {error}"
                ))
            })?;
            describe_metrics();
            Some(provider)
        } else {
            None
        };

        if let Some(ref provider) = tracer_provider {
            global::set_tracer_provider(provider.clone());
            global::set_text_map_propagator(TraceContextPropagator::new());
            let _ = install_trace_context_bridge(&OTEL_TRACE_CONTEXT_BRIDGE);
            #[cfg(feature = "postgres-sql-commenter")]
            if config.tracing().sql_commenter_enabled() {
                let _ = install_sql_commenter_hook(&OTEL_SQL_COMMENTER_HOOK);
            }
        }

        Ok(Self {
            meter_provider,
            tracer_provider,
            settings: config.settings(),
        })
    }

    #[must_use]
    pub const fn settings(&self) -> TelemetrySettings {
        self.settings
    }

    /// Returns whether an OTLP tracer provider was initialized.
    #[must_use]
    pub const fn traces_enabled(&self) -> bool {
        self.tracer_provider.is_some()
    }

    /// Flushes and shuts down all initialized providers.
    ///
    /// # Errors
    ///
    /// Returns an error if either provider fails to shut down.
    pub fn shutdown(self) -> Result<()> {
        let mut errors = Vec::new();

        if let Some(provider) = self.meter_provider {
            if let Err(error) = provider.shutdown() {
                errors.push(format!("Failed to shutdown meter provider: {error}"));
            }
        }

        if let Some(provider) = self.tracer_provider {
            if let Err(error) = provider.shutdown() {
                errors.push(format!("Failed to shutdown tracer provider: {error}"));
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            Err(DocumentDBError::internal_error(errors.join("; ")))
        }
    }
}

/// Installs the gateway's formatting subscriber and, when available, the OTLP
/// tracing layer.
pub fn init_tracing_subscriber(
    env_filter: EnvFilter,
    telemetry_manager: Option<&TelemetryManager>,
) {
    let registry = tracing_subscriber::registry()
        .with(env_filter)
        .with(tracing_subscriber::fmt::layer());

    let result = if let Some(provider) =
        telemetry_manager.and_then(|manager| manager.tracer_provider.as_ref())
    {
        registry
            .with(tracing_opentelemetry::OpenTelemetryLayer::new(
                GatewayTracer(provider.tracer(instrumentation::SCOPE)),
            ))
            .try_init()
    } else {
        registry.try_init()
    };

    if let Err(error) = result {
        eprintln!("documentdb-gateway: failed to install tracing subscriber: {error}");
    }
}

fn validate_attributes(attributes: Option<&HashMap<String, String>>) -> Result<()> {
    let Some(attributes) = attributes else {
        return Ok(());
    };

    for key in [
        resource_attributes::SERVICE_NAME,
        resource_attributes::SERVICE_VERSION,
    ] {
        if attributes.contains_key(key) {
            return Err(DocumentDBError::bad_value(format!(
                "Telemetry attributes should not include '{key}' as it is set automatically from the TelemetryConfig"
            )));
        }
    }

    Ok(())
}

fn create_resource(
    config: &TelemetryConfig,
    attributes: Option<HashMap<String, String>>,
) -> Resource {
    let env_attributes = config::resource_attributes()
        .into_iter()
        .map(|(key, value)| KeyValue::new(key, value));
    let caller_attributes = attributes
        .unwrap_or_default()
        .into_iter()
        .map(|(key, value)| KeyValue::new(key, value));

    Resource::builder()
        .with_attributes(env_attributes)
        .with_attributes(caller_attributes)
        .with_attribute(KeyValue::new(
            resource_attributes::SERVICE_NAME,
            config.service_name(),
        ))
        .with_attribute(KeyValue::new(
            resource_attributes::SERVICE_VERSION,
            config.service_version(),
        ))
        .build()
}

fn create_metrics_provider(
    config: &MetricsConfig,
    resource: Resource,
) -> Result<Option<(SdkMeterProvider, Recorder)>> {
    if !config.enabled() {
        return Ok(None);
    }

    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_temporality(Temporality::Delta)
        .with_tonic()
        .with_endpoint(config.otlp_endpoint())
        .with_protocol(opentelemetry_otlp::Protocol::Grpc)
        .with_timeout(Duration::from_millis(config.export_timeout_ms()))
        .build()
        .map_err(|error| {
            DocumentDBError::internal_error(format!("Failed to build metrics exporter: {error}"))
        })?;

    let reader = PeriodicReader::builder(exporter)
        .with_interval(Duration::from_millis(config.export_interval_ms()))
        .build();

    Ok(Some(
        Recorder::builder(instrumentation::SCOPE)
            .with_meter_provider(|builder| builder.with_resource(resource).with_reader(reader))
            .build(),
    ))
}

fn create_tracer_provider(
    config: &TracingConfig,
    resource: Resource,
) -> Result<Option<SdkTracerProvider>> {
    if !config.enabled() {
        return Ok(None);
    }

    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_endpoint(config.otlp_endpoint())
        .with_protocol(opentelemetry_otlp::Protocol::Grpc)
        .with_timeout(Duration::from_millis(config.export_timeout_ms()))
        .build()
        .map_err(|error| {
            DocumentDBError::internal_error(format!("Failed to build span exporter: {error}"))
        })?;

    let sampler =
        Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(config.sampler_ratio())));
    let provider = SdkTracerProvider::builder()
        .with_sampler(sampler)
        .with_id_generator(RandomIdGenerator::default())
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build();

    Ok(Some(provider))
}

fn describe_metrics() {
    metrics::describe_histogram!(
        metric_names::DB_CLIENT_OPERATION_DURATION,
        metrics::Unit::Seconds,
        "Duration of database client operations"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_OPERATIONS,
        metrics::Unit::Count,
        "Count of database client operations"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_REQUEST_SIZE_TOTAL,
        metrics::Unit::Bytes,
        "Total size of database client request payloads"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_RESPONSE_SIZE_TOTAL,
        metrics::Unit::Bytes,
        "Total size of database client response payloads"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_DOCUMENTS_RETURNED,
        metrics::Unit::Count,
        "Documents returned by read operations"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_DOCUMENTS_INSERTED,
        metrics::Unit::Count,
        "Documents inserted"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_DOCUMENTS_UPDATED,
        metrics::Unit::Count,
        "Documents updated"
    );
    metrics::describe_counter!(
        metric_names::DB_CLIENT_DOCUMENTS_DELETED,
        metrics::Unit::Count,
        "Documents deleted"
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

#[derive(Debug)]
struct OpenTelemetryTraceContextBridge;

static OTEL_TRACE_CONTEXT_BRIDGE: OpenTelemetryTraceContextBridge = OpenTelemetryTraceContextBridge;

#[cfg(feature = "postgres-sql-commenter")]
#[derive(Debug)]
struct OpenTelemetrySqlCommenterHook;

#[cfg(feature = "postgres-sql-commenter")]
static OTEL_SQL_COMMENTER_HOOK: OpenTelemetrySqlCommenterHook = OpenTelemetrySqlCommenterHook;

#[cfg(feature = "postgres-sql-commenter")]
impl SqlCommenterHook for OpenTelemetrySqlCommenterHook {
    fn current_comment(&self) -> Option<String> {
        let context = tracing::Span::current().context();
        let span = context.span();
        let span_context = span.span_context();
        if !span_context.is_valid() || !span_context.is_sampled() {
            return None;
        }

        Some(format_traceparent_comment(span_context))
    }
}

#[cfg(feature = "postgres-sql-commenter")]
fn format_traceparent_comment(span_context: &SpanContext) -> String {
    format!(
        "/*traceparent='00-{}-{}-{:02x}'*/",
        span_context.trace_id(),
        span_context.span_id(),
        span_context.trace_flags().to_u8()
    )
}

impl TraceContextBridge for OpenTelemetryTraceContextBridge {
    fn set_parent(&self, span: &tracing::Span, traceparent: &str) -> bool {
        let Some(parent) = parse_traceparent(traceparent) else {
            return false;
        };

        let span_context =
            SpanContext::new(parent.0, parent.1, parent.2, true, TraceState::default());
        span.set_parent(Context::current().with_remote_span_context(span_context))
            .is_ok()
    }
}

#[derive(Debug, Clone)]
struct GatewayTracer(SdkTracer);

impl Tracer for GatewayTracer {
    type Span = GatewaySpan<<SdkTracer as Tracer>::Span>;

    fn build_with_context(&self, mut builder: SpanBuilder, parent_cx: &Context) -> Self::Span {
        if builder.span_kind.is_none() {
            builder.span_kind = Some(take_span_kind(&mut builder));
        }
        let status = take_span_status(&mut builder);
        let mut span = GatewaySpan(self.0.build_with_context(builder, parent_cx), status);
        span.apply_status();
        span
    }
}

#[derive(Debug)]
struct GatewaySpan<S>(S, GatewaySpanStatus);

impl<S: OpenTelemetrySpan> GatewaySpan<S> {
    fn apply_status(&mut self) {
        if let Some(status) = self.1.as_otel_status() {
            self.0.set_status(status);
        }
    }
}

impl<S: OpenTelemetrySpan> OpenTelemetrySpan for GatewaySpan<S> {
    fn add_event_with_timestamp<T>(
        &mut self,
        name: T,
        timestamp: SystemTime,
        attributes: Vec<KeyValue>,
    ) where
        T: Into<Cow<'static, str>>,
    {
        self.0.add_event_with_timestamp(name, timestamp, attributes);
    }

    fn span_context(&self) -> &SpanContext {
        self.0.span_context()
    }

    fn is_recording(&self) -> bool {
        self.0.is_recording()
    }

    fn set_attribute(&mut self, attribute: KeyValue) {
        match attribute.key.as_str() {
            span_fields::STATUS_CODE => {
                if let Some(code) = status_code_from_value(&attribute.value) {
                    self.1.code = Some(code);
                    self.apply_status();
                    return;
                }
            }
            span_fields::STATUS_MESSAGE => {
                self.1.message = Some(attribute.value.as_str().into_owned());
                self.apply_status();
                return;
            }
            _ => {}
        }
        self.0.set_attribute(attribute);
    }

    fn set_status(&mut self, status: Status) {
        self.0.set_status(status);
    }

    fn update_name<T>(&mut self, new_name: T)
    where
        T: Into<Cow<'static, str>>,
    {
        self.0.update_name(new_name);
    }

    fn add_link(&mut self, span_context: SpanContext, attributes: Vec<KeyValue>) {
        self.0.add_link(span_context, attributes);
    }

    fn end_with_timestamp(&mut self, timestamp: SystemTime) {
        self.0.end_with_timestamp(timestamp);
    }
}

fn take_span_kind(builder: &mut SpanBuilder) -> SpanKind {
    let Some(attributes) = builder.attributes.as_mut() else {
        return SpanKind::Internal;
    };
    let Some(index) = attributes
        .iter()
        .position(|attribute| attribute.key.as_str() == span_fields::KIND)
    else {
        return SpanKind::Internal;
    };
    let kind = match attributes[index].value.as_str().as_ref() {
        "internal" => Some(SpanKind::Internal),
        "server" => Some(SpanKind::Server),
        "client" => Some(SpanKind::Client),
        "producer" => Some(SpanKind::Producer),
        "consumer" => Some(SpanKind::Consumer),
        _ => None,
    };
    let Some(kind) = kind else {
        return SpanKind::Internal;
    };
    attributes.remove(index);
    kind
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GatewaySpanStatusCode {
    Ok,
    Error,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct GatewaySpanStatus {
    code: Option<GatewaySpanStatusCode>,
    message: Option<String>,
}

impl GatewaySpanStatus {
    fn as_otel_status(&self) -> Option<Status> {
        match self.code {
            Some(GatewaySpanStatusCode::Ok) => Some(Status::Ok),
            Some(GatewaySpanStatusCode::Error) => {
                Some(Status::error(self.message.clone().unwrap_or_default()))
            }
            None => self.message.clone().map(Status::error),
        }
    }
}

fn take_span_status(builder: &mut SpanBuilder) -> GatewaySpanStatus {
    let mut status = GatewaySpanStatus::default();
    let Some(attributes) = builder.attributes.as_mut() else {
        return status;
    };

    if let Some(index) = attributes
        .iter()
        .position(|attribute| attribute.key.as_str() == span_fields::STATUS_CODE)
    {
        if let Some(code) = status_code_from_value(&attributes[index].value) {
            status.code = Some(code);
            attributes.remove(index);
        }
    }

    if let Some(index) = attributes
        .iter()
        .position(|attribute| attribute.key.as_str() == span_fields::STATUS_MESSAGE)
    {
        status.message = Some(attributes.remove(index).value.as_str().into_owned());
    }

    status
}

fn status_code_from_value(value: &opentelemetry::Value) -> Option<GatewaySpanStatusCode> {
    let value = value.as_str();
    if value.eq_ignore_ascii_case("ok") {
        Some(GatewaySpanStatusCode::Ok)
    } else if value.eq_ignore_ascii_case("error") {
        Some(GatewaySpanStatusCode::Error)
    } else {
        None
    }
}

fn parse_traceparent(traceparent: &str) -> Option<(TraceId, SpanId, TraceFlags)> {
    let mut parts = traceparent.split('-');
    if parts.next()? != "00" {
        return None;
    }
    let trace_id = TraceId::from_hex(parts.next()?).ok()?;
    let span_id = SpanId::from_hex(parts.next()?).ok()?;
    let flags = TraceFlags::new(u8::from_str_radix(parts.next()?, 16).ok()?);
    if parts.next().is_some() || trace_id == TraceId::INVALID || span_id == SpanId::INVALID {
        return None;
    }

    Some((trace_id, span_id, flags))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[derive(Debug)]
    struct TestSpan {
        context: SpanContext,
        attributes: Vec<KeyValue>,
        status: Status,
    }

    impl Default for TestSpan {
        fn default() -> Self {
            Self {
                context: SpanContext::NONE,
                attributes: Vec::new(),
                status: Status::Unset,
            }
        }
    }

    impl OpenTelemetrySpan for TestSpan {
        fn add_event_with_timestamp<T>(
            &mut self,
            _name: T,
            _timestamp: SystemTime,
            _attributes: Vec<KeyValue>,
        ) where
            T: Into<Cow<'static, str>>,
        {
        }

        fn span_context(&self) -> &SpanContext {
            &self.context
        }

        fn is_recording(&self) -> bool {
            true
        }

        fn set_attribute(&mut self, attribute: KeyValue) {
            self.attributes.push(attribute);
        }

        fn set_status(&mut self, status: Status) {
            self.status = status;
        }

        fn update_name<T>(&mut self, _new_name: T)
        where
            T: Into<Cow<'static, str>>,
        {
        }

        fn add_link(&mut self, _span_context: SpanContext, _attributes: Vec<KeyValue>) {}

        fn end_with_timestamp(&mut self, _timestamp: SystemTime) {}
    }

    #[test]
    fn rejects_reserved_resource_attributes() {
        let mut attributes = HashMap::new();
        attributes.insert(
            resource_attributes::SERVICE_NAME.to_owned(),
            "override".to_owned(),
        );
        assert!(validate_attributes(Some(&attributes)).is_err());
    }

    #[test]
    fn disabled_providers_are_not_created() {
        let options = json!({
            "Metrics": { "Enabled": false },
            "Tracing": { "Enabled": false }
        });
        let config = TelemetryConfig::new(Some(&options)).expect("configuration should parse");
        let resource = Resource::builder().build();

        assert!(create_metrics_provider(config.metrics(), resource.clone())
            .expect("disabled metrics should not fail")
            .is_none());
        assert!(create_tracer_provider(config.tracing(), resource)
            .expect("disabled tracing should not fail")
            .is_none());
    }

    #[test]
    fn validates_w3c_traceparent() {
        let parsed = parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
            .expect("traceparent should be valid");
        assert_eq!(parsed.0.to_string(), "4bf92f3577b34da6a3ce929d0e0e4736");
        assert_eq!(parsed.1.to_string(), "00f067aa0ba902b7");
        assert!(parsed.2.is_sampled());
    }

    #[test]
    fn rejects_invalid_w3c_traceparent() {
        assert!(parse_traceparent("invalid").is_none());
        assert!(
            parse_traceparent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").is_none()
        );
    }

    #[cfg(feature = "postgres-sql-commenter")]
    #[test]
    fn formats_sampled_traceparent_sql_comment() {
        let span_context = SpanContext::new(
            TraceId::from_hex("0af7651916cd43dd8448eb211c80319c").expect("valid trace ID"),
            SpanId::from_hex("b7ad6b7169203331").expect("valid span ID"),
            TraceFlags::SAMPLED,
            false,
            TraceState::default(),
        );
        let comment = format_traceparent_comment(&span_context);

        assert_eq!(
            comment,
            "/*traceparent='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'*/"
        );
        assert!(!comment
            .trim_start_matches("/*")
            .trim_end_matches("*/")
            .contains("*/"));
    }

    #[test]
    fn maps_and_consumes_provider_neutral_span_kind() {
        for (value, expected) in [
            ("internal", SpanKind::Internal),
            ("server", SpanKind::Server),
            ("client", SpanKind::Client),
            ("producer", SpanKind::Producer),
            ("consumer", SpanKind::Consumer),
        ] {
            let mut builder = SpanBuilder::from_name("test")
                .with_attributes([KeyValue::new(span_fields::KIND, value)]);
            assert_eq!(take_span_kind(&mut builder), expected);
            assert!(builder.attributes.as_ref().is_some_and(Vec::is_empty));
        }
    }

    #[test]
    fn defaults_missing_or_unknown_provider_neutral_span_kind_to_internal() {
        let mut builder = SpanBuilder::from_name("test");
        assert_eq!(take_span_kind(&mut builder), SpanKind::Internal);

        let mut builder = SpanBuilder::from_name("test")
            .with_attributes([KeyValue::new(span_fields::KIND, "unknown")]);
        assert_eq!(take_span_kind(&mut builder), SpanKind::Internal);
        assert_eq!(builder.attributes.as_ref().map(Vec::len), Some(1));
    }

    #[test]
    fn maps_and_consumes_initial_provider_neutral_status_code() {
        for (value, code, expected) in [
            ("ok", GatewaySpanStatusCode::Ok, Status::Ok),
            ("ERROR", GatewaySpanStatusCode::Error, Status::error("")),
        ] {
            let mut builder = SpanBuilder::from_name("test")
                .with_attributes([KeyValue::new(span_fields::STATUS_CODE, value)]);
            let status = take_span_status(&mut builder);
            assert_eq!(status.code, Some(code));
            assert_eq!(status.as_otel_status(), Some(expected));
            assert!(builder.attributes.as_ref().is_some_and(Vec::is_empty));
        }
    }

    #[test]
    fn maps_and_consumes_initial_provider_neutral_status_message() {
        let mut builder = SpanBuilder::from_name("test").with_attributes([
            KeyValue::new(span_fields::STATUS_CODE, "error"),
            KeyValue::new(span_fields::STATUS_MESSAGE, "operation failed"),
        ]);
        let status = take_span_status(&mut builder);

        assert_eq!(
            status.as_otel_status(),
            Some(Status::error("operation failed"))
        );
        assert!(builder.attributes.as_ref().is_some_and(Vec::is_empty));
    }

    #[test]
    fn maps_dynamic_provider_neutral_status_fields() {
        let mut span = GatewaySpan(TestSpan::default(), GatewaySpanStatus::default());
        span.set_attributes([
            KeyValue::new(span_fields::STATUS_MESSAGE, "operation failed"),
            KeyValue::new(span_fields::STATUS_CODE, "error"),
            KeyValue::new("operation", "find"),
        ]);

        assert_eq!(span.0.status, Status::error("operation failed"));
        assert_eq!(span.0.attributes, [KeyValue::new("operation", "find")]);
    }

    #[test]
    fn preserves_unknown_provider_neutral_status_code() {
        let mut builder = SpanBuilder::from_name("test")
            .with_attributes([KeyValue::new(span_fields::STATUS_CODE, "bad")]);
        assert_eq!(take_span_status(&mut builder), GatewaySpanStatus::default());
        assert_eq!(builder.attributes.as_ref().map(Vec::len), Some(1));

        let mut span = GatewaySpan(TestSpan::default(), GatewaySpanStatus::default());
        span.set_attribute(KeyValue::new(span_fields::STATUS_CODE, "bad"));
        assert_eq!(span.0.status, Status::Unset);
        assert_eq!(span.0.attributes.len(), 1);
    }
}
