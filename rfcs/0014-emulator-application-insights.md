---
rfc: 0014
title: "Application Insights Telemetry for DocumentDB Local Emulator"
status: Draft
owner: "@Ritvik-Jayaswal"
issue: "https://github.com/documentdb/documentdb/issues/XXX"
discussion: "https://github.com/documentdb/documentdb/discussions/XXX"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/XXX"
---

# RFC-0014: Application Insights Telemetry for DocumentDB Local Emulator

## Problem

The DocumentDB local emulator lacks structured, actionable telemetry. Without it, the team has no visibility into how users interact with the emulator: which features they exercise, what kinds of queries they run, where they encounter errors, and whether the emulator is being used at all or abandoned quickly.

### Who Is Impacted

- **Product and engineering teams** — cannot make data-driven decisions about which features to prioritize, which bugs matter most, or where the emulator diverges from customer expectations.
- **Customers** — indirectly affected when compatibility gaps and pain points are invisible to the team and therefore remain unresolved.

### Consequences of Not Solving This

- Investment is allocated to features that aren't being used, while real friction points remain invisible.
- Query incompatibilities or emulator bugs that affect large numbers of users go undetected until customers escalate manually.
- There is no baseline to measure the impact of improvements.

### Current State

The emulator entrypoint already exposes an `--enable-telemetry` flag (and `ENABLE_TELEMETRY` environment variable) in [`scripts/emulator_entrypoint.sh`](../scripts/emulator_entrypoint.sh), but the flag is only validated — it is never forwarded to the gateway component or used to enable any telemetry pipeline. No telemetry data is currently collected or transmitted. This RFC proposes renaming the flag to `--disable-telemetry` (with `USAGE_TRACKING` as the environment variable) to reflect the opt-out model described below.

A comparable implementation was completed for the DocumentDB Kubernetes Operator ([PR #237](https://github.com/documentdb/documentdb-kubernetes-operator/pull/237)), which integrated the Microsoft Application Insights Go SDK, wired telemetry into controllers, and exposed Helm chart configuration for the connection string. This RFC adapts that approach for the emulator context.

### Success Criteria

1. By default (telemetry is enabled unless explicitly disabled), the emulator emits structured events to Application Insights without any observable impact on functional behavior.
2. No personally identifiable information (PII), credentials, collection names, field names, or raw query values are ever transmitted.
3. Telemetry captures all MongoDB operation types (find, aggregate, insert, update, delete, and all command subtypes) with a focus on operations that produce errors, without capturing actual values.
4. Users can opt out at any time by passing `--disable-telemetry` or setting `USAGE_TRACKING=false` (proposed rename from the existing `ENABLE_TELEMETRY`).
5. Telemetry is silently disabled if the Application Insights connection string is absent or malformed, with a single log warning — it must never crash the emulator.

---

## Approach

### Proposed Solution

Deploy the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) as an additional component inside the emulator container, managed entirely by the existing entrypoint script. The collector hosts **two independent pipelines** because they have fundamentally different data handling requirements — data sent to App Insights leaves the user's machine and must be PII-scrubbed, while data for the user's own debugging stays local and should retain full detail:

1. **Application Insights pipeline** (PII-scrubbed) — collects gateway operation data and entrypoint lifecycle events, processes them through a scrubbing pipeline to strip all PII, and exports to Application Insights via the `azuremonitorexporter`. This is the focus of this RFC.
2. **User observability pipeline** (no PII restrictions) — forwards gateway logs, PostgreSQL logs, and script logs to a local endpoint or stdout for the user's own debugging and monitoring. This pipeline has no PII filtering since the data never leaves the user's machine.

In the first phase, no changes are made to the gateway or PostgreSQL source code. The only code changes are to the OTel Collector configuration file and the emulator entrypoint script. The Application Insights connection string is **baked into the release build** via a CI/CD secret, so users never need to supply it. Opt-in/opt-out is controlled by the `USAGE_TRACKING` environment variable (default: `true`) or the `--disable-telemetry` flag.

### Key Benefits and Tradeoffs

| Benefit | Tradeoff |
|---|---|
| Actionable usage data with zero configuration burden on users | Requires baking a connection string into the release artifact (mitigated: read-only ingestion key, no data exfiltration risk) |
| Consistent with Application Insights already used across the DocumentDB ecosystem | Adds the OTel Collector binary to the emulator container image (~100 MB) |
| Enabled by default maximizes data coverage and issue detection | Users must explicitly opt out; clear disclosure at first run required |
| Tracking all Mongo operations (especially errors) reveals compatibility gaps | Requires careful scrubbing logic to ensure no value leakage |

### Alignment with Existing Architecture

The emulator entrypoint script ([`scripts/emulator_entrypoint.sh`](../scripts/emulator_entrypoint.sh)) already manages the full lifecycle of the PostgreSQL server and gateway component. Adding the OTel Collector as another managed child component follows the same pattern — start on launch, stop on shutdown — without any changes to the gateway or PostgreSQL source code.

---

## Detailed Design

### Technical Details

#### OTel Collector Configuration

The OpenTelemetry Collector is a single binary that runs as a managed child component of the emulator entrypoint. Its configuration file (`otelcol-config.yaml`) defines two independent *pipelines* — a pipeline being an OTel Collector concept consisting of receivers, processors, and exporters wired together:

##### Pipeline 1: Application Insights (PII-scrubbed)

This pipeline is the primary focus of this RFC. It collects gateway and lifecycle telemetry, scrubs all PII, and exports to Application Insights.

**Receivers**
- `filelogreceiver` (gateway logs) — tails the gateway log file, extracting MongoDB operation types, error codes, and command names using regex operators. This is the primary data source for App Insights. No query values are captured.
- `filelogreceiver` (entrypoint lifecycle) — reads structured lifecycle events (`EmulatorStarted`, `EmulatorStopped`, `InitDataLoaded`) emitted by the entrypoint script to a dedicated log file.
- `filelogreceiver` (PostgreSQL logs) — tails PostgreSQL log files to capture crash reports and fatal errors for reliability tracking.

**Processors**
- `transformprocessor` — normalizes gateway log entries into a bucketed MongoDB operation type (`find`, `aggregate`, `insert`, `update`, `delete`, `getMore`, `listCollections`, `createIndexes`, `dropDatabase`, and all other command subtypes) and extracts pipeline stage names for aggregate queries.
- `filterprocessor` — drops any attribute whose key or value matches a blocklist of known PII patterns (collection names, usernames, hostnames, IP addresses, file paths).
- `resourceprocessor` — attaches static resource attributes: `emulator.version`, `environment` tag, and `container.id` (the Docker container ID, read from `$HOSTNAME`).
- `batchprocessor` — batches up to 100 data points or flushes every 30 seconds before export.

**Exporter**
- `azuremonitorexporter` — sends processed telemetry to Application Insights. The connection string is provided via the `APPLICATIONINSIGHTS_CONNECTION_STRING` environment variable, injected from a CI/CD secret at release build time and forwarded by the entrypoint script.

##### Pipeline 2: User Observability (no PII restrictions)

This pipeline forwards all logs to the user's local environment for debugging. Since data never leaves the user's machine, no PII filtering is applied.

**Receivers**
- `filelogreceiver` — tails gateway logs, PostgreSQL logs, and entrypoint script logs.

**Processors**
- `resourceprocessor` — attaches `emulator.version` and `container.id` for context.

**Exporter**
- Logs are written to stdout / a local log file. In the future, this pipeline can be extended to support user-configured OTLP endpoints.

#### Container Correlation

The entrypoint script reads the Docker container ID from the `$HOSTNAME` environment variable (which Docker sets to the container's short ID by default) and passes it to the OTel Collector as `CONTAINER_ID`. The `resourceprocessor` attaches it as the `container.id` resource attribute on every exported data point. This correlates events within a single container instance. The container ID changes on every `docker run`, so it does not track users across separate container invocations.

#### PII Scrubbing

The `filterprocessor` and `transformprocessor` in the App Insights pipeline enforce the following rules:

- **Never included:** raw query text, literal values, database names, collection names, field names, index names, usernames, hostnames, IP addresses, file paths.
- **Safe to include:** emulator version, OS family, environment tag (`docker` / `codespaces` / `ci` / `bare-metal` / `unknown`), normalized MongoDB operation type (e.g., `find`, `aggregate`, `createIndexes`), pipeline stage names (MongoDB spec names, not user data), error code integers, duration histograms, container ID.

These rules apply **only to the App Insights pipeline**. The user observability pipeline has no PII restrictions since all data stays on the user's machine.

#### Metrics and Events Collected

**MongoDB operation metrics** (sourced from gateway logs, aggregated per flush interval):

| Metric | Type | Description |
|---|---|---|
| `documentdb.operation.count` | Counter | Number of executions per MongoDB operation type (find, aggregate, insert, update, delete, getMore, listCollections, createIndexes, etc.) |
| `documentdb.operation.duration` | Histogram | Execution time distribution per operation type |
| `documentdb.operation.errors` | Counter | Failed operations per error code and operation type — **primary signal for compatibility gap detection** |
| `documentdb.operation.error_ratio` | Gauge | Ratio of failed to total operations per type, for alerting |

**Lifecycle events** (emitted by the entrypoint script to a dedicated log file read by `filelogreceiver`):

| Event | When Emitted | Key Attributes |
|---|---|---|
| `EmulatorStarted` | Gateway ready to accept connections | `emulator_version`, `container_id`, `environment`, `tls_enabled`, `extended_rum_enabled` |
| `EmulatorStopped` | Graceful shutdown signal received | `container_id`, `uptime_seconds` |
| `InitDataLoaded` | Sample or custom init data loaded | `container_id`, `data_source` (`sample` / `custom`) |

**PostgreSQL crash reports** (sourced from PostgreSQL log files, optional):

| Event | When Emitted | Key Attributes |
|---|---|---|
| `PostgresFatalError` | PostgreSQL emits a FATAL or PANIC log entry | `container_id`, `error_code`, `error_severity` |

### API Changes

No public-facing API changes and no changes to the gateway or PostgreSQL source code. The `--disable-telemetry` flag and `USAGE_TRACKING` environment variable replace the existing `--enable-telemetry` / `ENABLE_TELEMETRY` in the entrypoint; this RFC gives them a real implementation by starting and stopping the OTel Collector component.

### Database Schema Changes

None.

### Configuration Changes

| Setting | Where | Default | Description |
|---|---|---|---|
| `USAGE_TRACKING` | Env var / `--disable-telemetry` CLI flag | `true` | Master switch for Application Insights telemetry. Set to `false` or pass `--disable-telemetry` to opt out. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Build-time env var (CI secret) | *(injected at release build)* | Application Insights ingestion endpoint + key. Never user-facing. |
| `CONTAINER_ID` | Read from `$HOSTNAME` at startup | *(Docker container short ID)* | Passed to the OTel Collector as the `container.id` resource attribute. |

The entrypoint script ([`scripts/emulator_entrypoint.sh`](../scripts/emulator_entrypoint.sh)) will be updated to:
1. Read `CONTAINER_ID` from `$HOSTNAME` at startup.
2. Unless `--disable-telemetry` is passed or `USAGE_TRACKING=false`, start the OTel Collector as a background component with `otelcol-config.yaml` and the above env vars.
3. On shutdown (in the existing `cleanup` function), send `SIGTERM` to the OTel Collector and wait up to 5 seconds for it to flush.

### Testing Strategy

- **OTel Collector config validation:** Use `otelcol validate --config otelcol-config.yaml` in CI to catch configuration errors before they reach users.
- **Integration tests:** Start the emulator with `USAGE_TRACKING=false` and verify the OTel Collector component is not spawned and no outbound HTTP traffic is produced. Start with `USAGE_TRACKING=true` (the default) and a mock OTLP receiver in place of Application Insights; verify that exported metric names and attributes match the spec above.
- **PII audit:** Automated test that runs a set of queries containing known sentinel string values and asserts those sentinels are absent from every metric attribute exported by the OTel Collector (inspected via the mock OTLP receiver).
- **Resilience tests:** Verify that if the OTel Collector crashes or the Application Insights endpoint is unreachable, the emulator continues serving queries without error.

### Migration Path

- Telemetry is enabled by default (`USAGE_TRACKING=true`). Existing users who previously set `ENABLE_TELEMETRY=true` should migrate to `USAGE_TRACKING=true` (or simply remove the setting, since `true` is now the default).
- Users who previously set `ENABLE_TELEMETRY=false` should migrate to `USAGE_TRACKING=false` or pass `--disable-telemetry`.
- The old `ENABLE_TELEMETRY` variable and `--enable-telemetry` flag will be accepted as deprecated aliases for one release cycle, with a deprecation warning logged at startup.

### Documentation Updates

- [`scripts/emulator_entrypoint.sh`](../scripts/emulator_entrypoint.sh): Replace `--enable-telemetry` with `--disable-telemetry`, update help text to describe what data is collected, and link to the privacy statement.
- `README.md` (emulator): Add a "Telemetry" section describing that usage tracking is enabled by default, what is and is not collected, and how to disable via `--disable-telemetry` or `USAGE_TRACKING=false`.
- Release notes: Disclose the telemetry addition clearly in the changelog entry for the first release containing this feature.
- Internal runbook: Document how to query the Application Insights workspace for usage and query shape reports.

---

## Implementation Tracking

*This section SHALL be populated during the Implementation phase.*

### Implementation PRs

- [ ] PR #XXX: Add `otelcol-config.yaml` (OTel Collector dual pipeline: App Insights with `filelogreceiver`, processors, `azuremonitorexporter`; user observability with local log output)
- [ ] PR #XXX: Update `scripts/emulator_entrypoint.sh` to read `CONTAINER_ID` from `$HOSTNAME`, start/stop the OTel Collector component, and emit lifecycle log events
- [ ] PR #XXX: CI/CD secret injection of `APPLICATIONINSIGHTS_CONNECTION_STRING` for release builds and inclusion of the OTel Collector binary in the container image
- [ ] PR #XXX: Documentation and README updates

### Status Updates

**2026-03-10:** RFC created and submitted for initial feedback.

### Open Questions

- [x] **Opt-in vs. opt-out default:** ~~Should telemetry default to `true` (opt-out) or remain `false` (opt-in)?~~
  - **Resolved:** Telemetry defaults to `true`. Users opt out via `--disable-telemetry` or `USAGE_TRACKING=false`.
- [x] **Query shape granularity for `command`:** ~~Should we emit individual command names or group all under `"command"`?~~
  - **Resolved:** Emit individual command subtypes (`listCollections`, `createIndexes`, `dropDatabase`, etc.) since these are MongoDB spec names, not user data.
- [ ] **Duration bucket resolution:** Are five duration buckets (0–1 ms, 1–10 ms, 10–100 ms, 100–1000 ms, 1000+ ms) sufficient, or should we include sub-millisecond and multi-second finer buckets?
  - Discussion: TBD

### Implementation Notes

*Capture important decisions or learnings during implementation*

- **Decision [2026-03-10]:** Use the OpenTelemetry Collector rather than embedding a telemetry SDK in the gateway, so that zero changes are needed to the gateway or PostgreSQL source code.
  - **Context:** The Kubernetes operator embedded the Go Application Insights SDK directly in the controller binary. For the emulator, the OTel Collector provides equivalent functionality as a standalone component, keeps the gateway source clean, and allows the telemetry pipeline to be updated by changing a YAML configuration file rather than recompiling the gateway.
  - **Alternatives:** Embedding the `opentelemetry` Rust crate or a custom Application Insights HTTP client in the gateway — rejected to avoid gateway source changes.
- **Decision [2026-03-16]:** Telemetry defaults to enabled (`USAGE_TRACKING=true`), with `--disable-telemetry` flag for opt-out.
  - **Context:** Per reviewer feedback, maximizing data coverage is critical for detecting compatibility gaps. The env var was renamed from `ENABLE_TELEMETRY` to `USAGE_TRACKING` to avoid overloading the term "telemetry" (which could be confused with OTel observability in general).
- **Decision [2026-03-16]:** Use Docker container ID (`$HOSTNAME`) instead of a random UUID for session correlation.
  - **Context:** The container ID is already unique per `docker run` invocation and is more useful for debugging than a random UUID. It does not persist across container restarts.
- **Decision [2026-03-16]:** The OTel Collector hosts two independent pipelines — one for App Insights (PII-scrubbed) and one for user observability (no PII restrictions, local only).
  - **Context:** Separating pipelines ensures PII scrubbing logic only applies to data leaving the machine, while users retain full visibility into their emulator's behavior for debugging.
