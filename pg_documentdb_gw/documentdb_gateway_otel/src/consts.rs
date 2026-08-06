/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/consts.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod instrumentation {
    pub const SCOPE: &str = "documentdb_gateway";
}

pub mod span_fields {
    pub const KIND: &str = "span.kind";
    pub const STATUS_CODE: &str = "span.status_code";
    pub const STATUS_MESSAGE: &str = "span.status_message";
}

// Environment variables used for configuration
pub mod env_vars {
    #[cfg(feature = "postgres-sql-commenter")]
    pub const DOCUMENTDB_SQL_COMMENTER_ENABLED: &str = "DOCUMENTDB_SQL_COMMENTER_ENABLED";
    pub const OTEL_EXPORTER_OTLP_ENDPOINT: &str = "OTEL_EXPORTER_OTLP_ENDPOINT";
    pub const OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: &str = "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT";
    pub const OTEL_EXPORTER_OTLP_METRICS_TIMEOUT: &str = "OTEL_EXPORTER_OTLP_METRICS_TIMEOUT";
    pub const OTEL_EXPORTER_OTLP_TIMEOUT: &str = "OTEL_EXPORTER_OTLP_TIMEOUT";
    pub const OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: &str = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT";
    pub const OTEL_EXPORTER_OTLP_TRACES_TIMEOUT: &str = "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT";
    pub const OTEL_METRIC_EXPORT_INTERVAL: &str = "OTEL_METRIC_EXPORT_INTERVAL";
    pub const OTEL_METRICS_ENABLED: &str = "OTEL_METRICS_ENABLED";
    pub const OTEL_RESOURCE_ATTRIBUTES: &str = "OTEL_RESOURCE_ATTRIBUTES";
    pub const OTEL_SERVICE_NAME: &str = "OTEL_SERVICE_NAME";
    pub const OTEL_SERVICE_VERSION: &str = "OTEL_SERVICE_VERSION";
    pub const OTEL_TRACES_ENABLED: &str = "OTEL_TRACES_ENABLED";
    pub const OTEL_TRACES_SAMPLER_ARG: &str = "OTEL_TRACES_SAMPLER_ARG";
}

pub mod resource_attributes {
    pub const SERVICE_NAME: &str = "service.name";
    pub const SERVICE_VERSION: &str = "service.version";
}
