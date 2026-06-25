# Contributing to pg_documentdb_gw

This document describes the project structure and conventions for the `pg_documentdb_gw` Rust workspace.

## Conventions

### Coding conventions

Do follow the Rust API guidelines and idiomatic Rust practices. We use `rustfmt` for code formatting and `clippy` for linting. Please ensure your code is formatted and free of warnings before submitting a PR.
For reference see:

- [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/about.html)
- [Pragmatic Rust Guidelines](https://microsoft.github.io/rust-guidelines/guidelines/index.html)

### Workspace Dependencies

All third-party dependencies are declared in the root `Cargo.toml` under `[workspace.dependencies]` and referenced by member crates with `.workspace = true`. Do not add dependency versions directly in member crate `Cargo.toml` files.

### Test Organization

Test helper functions in `documentdb_tests/src/commands/` are organized as one module per command (e.g., `insert.rs`, `find.rs`, `aggregate.rs`). These are consumed by integration tests in `documentdb_tests/tests/`.

### Telemetry

The gateway exposes OpenTelemetry-compatible **metrics** and **traces** via OTLP/gRPC. Both signals are opt-in. Enable them in `SetupConfiguration.json`:

```json
"TelemetryOptions": {
  "Metrics": { "Enabled": true, "OtlpEndpoint": "http://localhost:4317" },
  "Tracing": { "Enabled": true, "OtlpEndpoint": "http://localhost:4317", "SamplerRatio": 1.0 }
}
```

Or via the standard OpenTelemetry environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_ENABLED`, `OTEL_TRACES_SAMPLER_ARG`, `OTEL_METRICS_ENABLED`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_SERVICE_NAME`). JSON values take precedence over env vars; env vars take precedence over defaults.

Tracing emits a `gateway.request` root span per request with `db.system.name`, `db.operation.name`, `db.collection.name`, `db.namespace`, `connection.id`, `network.protocol`, and `network.transport.tls` attributes, plus nested spans (`gateway.read_request`, `gateway.format_request`, `gateway.auth`, `gateway.process_request`, `postgres.transaction`, `postgres.acquire_connection`, `postgres.execute`, `gateway.write_response`) that mirror the metric phase breakdown.

Sampling defaults to `ParentBased(TraceIdRatioBased(1.0))` — once tracing is enabled, every root span is sampled. Lower `SamplerRatio` to ratio-sample in production. The `OTEL_TRACES_SAMPLER` env var is intentionally ignored; only the ratio is configurable in v1.
