---
rfc: 0016
title: "Scarf Usage Telemetry for DocumentDB"
status: Draft
owner: "@RitvikJayaswal"
issue: "https://github.com/documentdb/documentdb/issues/XXX"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/XXX"
---

# RFC-0016: Scarf Usage Telemetry for DocumentDB

## Problem

DocumentDB is open source and distributed primarily as a container image
(`documentdb-local`) plus Linux packages. Today the project has **no reliable
signal of real-world adoption**: how many deployments exist, which versions and
platforms are in use, or whether usage is growing. Maintainers and stakeholders
have explicitly asked for open-source adoption numbers, and there is currently no
mechanism to produce them.

### Who is impacted

- **Maintainers / TSC** cannot quantify adoption to prioritize platforms,
  versions, and features, or to justify continued investment.
- **Contributors** lack data about which areas of the project are actually used.
- **Downstream stakeholders** (e.g., the sponsoring organization) cannot report
  meaningful OSS traction.

### Consequences of not solving it

Decisions about roadmap, platform support, and resourcing are made without
adoption data. Registry pull counts alone are misleading — a CI cache pull, a
mirror, or a re-pull of an unchanged image all look identical to a genuine new
deployment, and container registries (GHCR) expose little usable analytics.

### Current workarounds

- **GHCR pull counts:** coarse, easily inflated by CI, no per-version or
  per-platform breakdown, no geographic or organizational signal.
- **Manual anecdote:** issues, stars, Discord activity — not measurable.

### Success criteria

1. A privacy-respecting way to measure **real running deployments** (not just
   downloads), broken down by version and platform.
2. A way to measure **downloads** of the published artifacts.
3. **On by default**, opt-out, with a standard opt-out that always wins.
4. **Zero data** about user content, queries, schema names, or credentials.
5. **No cost** to the project or to users.
6. Fully auditable in the open-source tree.

### Non-goals

- This RFC does **not** replace or feed operational observability. Detailed
  per-request metrics for operators remain the job of the existing OpenTelemetry
  (OTLP) pipeline and are out of scope here except where the two intersect.
- This RFC does **not** collect any user data, and explicitly does not aim to
  identify individual users.
- This RFC does **not** introduce a general-purpose analytics framework.

---

## Approach

Adopt [Scarf](https://scarf.sh) as the open-source usage-analytics provider,
using two complementary, independent mechanisms:

1. **Distribution analytics (download counting).** Route the project's published
   container-image pull command through a Scarf Gateway domain. Scarf acts as a
   transparent redirect in front of the existing registry (GHCR): users still
   pull the same image with the same digest, but Scarf records the pull
   (version/tag, platform, coarse geo/organization) before redirecting. This
   requires no code — only a one-line change to the documented `docker pull`
   command — and captures **downloads**.

2. **Runtime usage telemetry (deployment counting).** Add a small, optional,
   privacy-respecting telemetry emitter to the **`documentdb-local` container
   entrypoint scripts** that sends two low-frequency events to a Scarf Event
   Collection endpoint: a one-time **launch** event and a periodic
   **heartbeat**. This captures **real running deployments** of
   `documentdb-local`, which downloads cannot. The OSS gateway
   (`pg_documentdb_gw`) is deliberately left untouched (see below).

### Why Scarf

- Purpose-built for open-source adoption analytics (downloads, running
  deployments, version/platform/geo, organization enrichment).
- **Free** for this use: Scarf does not charge for event ingestion, telemetry
  volume, or download traffic at any volume.
- Transparent redirect model means the container image itself is unchanged
  (same digest, same registry backend); distribution can be re-pointed later
  without changing the user's pull command.
- Honors `DO_NOT_TRACK` and provides a documented, cookie-free model.

### Why two mechanisms

Downloads and deployments answer different questions. A download count is
inflated by CI and mirrors and says nothing about whether the software is
actually run. A launch/heartbeat signal measures real deployments by
version/platform. Together they give an adoption funnel (downloaded → run).

### Key tradeoffs

- **Runtime telemetry is inherently a network call from the container.**
  We mitigate this by making it low-frequency, fire-and-forget, and fully
  documented, and by honoring a standard, always-winning opt-out
  (`DO_NOT_TRACK` / `SCARF_NO_ANALYTICS`) — following Scarf's own best-practice
  guidance (low-frequency, high-intent events only). It is enabled by default
  (opt-out) so adoption numbers reflect real usage rather than the small
  fraction who would explicitly opt in.
- **A user-facing documentation change** is required for download tracking (the
  published pull command must point at the Scarf domain). This is a
  one-line, reversible change with no code impact.

### Fit with existing architecture

The runtime emitter lives entirely in the **`documentdb-local` container
entrypoint scripts** (`documentdb-local/scripts/`), alongside — but strictly
separate from — the container's existing PostgreSQL and gateway startup logic.
It runs as a lightweight background process spawned by `emulator_entrypoint.sh`,
uses only tools already present in the image (`curl`, `uname`), and never
touches the request/response data path. It is independent of the gateway's
existing OpenTelemetry (OTLP) telemetry.

### Why the OSS gateway is deliberately out of scope

The OSS gateway (`pg_documentdb_gw`) is **not** modified by this RFC. That
gateway is a shared library shipped and run in production environments
(including hosted pgmongo), where emitting Scarf adoption telemetry from the
request path would be inappropriate. Scoping runtime telemetry to the
`documentdb-local` entrypoint scripts keeps adoption measurement confined to the
local/dev container image that is actually distributed for adoption tracking,
and guarantees zero behavioral, dependency, or performance impact on the
production gateway.

---

## Detailed Design

### Two independent telemetry systems (must not be conflated)

DocumentDB will have two separate systems that both deal with "metrics." They
are controlled independently and send to different destinations.

| | Operational metrics (OTLP) | Usage telemetry (Scarf) |
|---|---|---|
| Audience | The **operator** running the instance | The **maintainers** of the project |
| Transport | OpenTelemetry OTLP (gRPC) | Plain HTTPS GET to Scarf endpoint |
| Destination | An endpoint the operator configures (Prometheus, Grafana, App Insights) | Scarf Event Collection endpoint |
| Granularity | Per-request, high-cardinality | Low-frequency (launch + heartbeat) |
| Toggle | `OTEL_METRICS_ENABLED` (+ `OTEL_*`) | `SCARF_ANALYTICS_ENABLED` |
| Default | Off | On (opt-out) |

The rest of this section specifies the Scarf usage telemetry.

### Exactly what `documentdb-local` collects and sends

When (and only when) usage telemetry is enabled, the `documentdb-local`
entrypoint script sends HTTPS requests to a Scarf Event Collection endpoint.
There are exactly **two** event types, encoded as URL query parameters (no
request body).

#### Event: `emulator_launch` (sent once, shortly after container startup)

| Field | Example | Meaning |
|-------|---------|---------|
| `event` | `emulator_launch` | Event type |
| `version` | `0.104.0` | `documentdb-local` release version (from `/version.txt`) |
| `os` | `linux` | Operating system (`uname -s`) |
| `arch` | `x86_64` | CPU architecture (`uname -m`) |
| `db_system` | `documentdb` | Constant identifier |

#### Event: `emulator_heartbeat` (sent periodically; default hourly)

A liveness signal that a deployment is still running. It carries only the same
host attributes as the launch event — no per-request, per-collection, or
per-user data of any kind. Counting distinct deployments emitting heartbeats
over time yields the running-deployment signal.

| Field | Example | Meaning |
|-------|---------|---------|
| `event` | `emulator_heartbeat` | Event type |
| `version`, `os`, `arch`, `db_system` | (as above) | Same host attributes |

That is the complete list of transmitted fields. There are no hidden fields.
Because the emitter runs in the entrypoint script and has no visibility into the
gateway's request path, it collects **no** document-throughput or operation
counts.

### What is never collected

The emitter never reads, constructs, or transmits:

- **User data** — no document contents, field names, or values.
- **Queries** — no filters, aggregation pipelines, or command arguments.
- **User-chosen names** — no database names, collection names, index names, or
  user names.
- **Credentials** — no passwords, connection strings, tokens, or keys.
- **Network identity in the payload** — the gateway does not put IP addresses in
  events. (As with any HTTPS request, the receiving service observes the
  connection's source address and may derive coarse geo/organization signal from
  it; this is inherent to making a network request, not something the payload
  carries.)

### No changes to the OSS gateway or its metrics

This RFC does **not** touch the OSS gateway (`pg_documentdb_gw`), its OTLP
operational metrics, or any of its telemetry attributes. Because the Scarf
emitter lives in the `documentdb-local` entrypoint scripts and only ever sends
the constant host attributes listed above, no user-defined identifier (database
name, collection name, index name, user name) is ever read or transmitted — so
there is nothing to hash or redact. The gateway's existing OTLP pipeline is
unchanged.

### Configuration

All configuration is read by the `documentdb-local` entrypoint scripts from
environment variables (and the matching entrypoint flags). Resolution order for
each setting: environment variable / flag > built-in default. User opt-out
overrides everything.

| Setting | Env var | Entrypoint flag | Default |
|---------|---------|-----------------|---------|
| Enable | `SCARF_ANALYTICS_ENABLED` | `--usage-analytics [true\|false]` | `true` (on) |
| Endpoint | `SCARF_TELEMETRY_ENDPOINT` | — | `https://documentdb.gateway.scarf.sh/telemetry` |
| Heartbeat interval (s) | `SCARF_HEARTBEAT_INTERVAL_S` | — | `3600` (1 hour) |
| Opt out | `DO_NOT_TRACK=1` **or** `SCARF_NO_ANALYTICS=1` | `--disable-usage-analytics` | not set |

Usage analytics is **on by default (opt-out)**. Setting
`SCARF_ANALYTICS_ENABLED=false`, passing `--disable-usage-analytics`, or setting
either standard opt-out variable (`DO_NOT_TRACK=1` / `SCARF_NO_ANALYTICS=1`)
disables it; the opt-out always wins over any enable.

This Scarf usage-analytics toggle is separate from the existing
`--enable-telemetry` / `ENABLE_TELEMETRY` flag (which controls the gateway's
Azure Application Insights / OTLP operational telemetry) and does not change its
behavior.

The default endpoint (`documentdb.gateway.scarf.sh`) is a placeholder for an
**official DocumentDB-owned Scarf organization** that must be registered before
release (see Open Issues). Until registered, requests to it fail silently and
harmlessly.

### Technical Details

**Location.** All logic lives in the `documentdb-local` container scripts
(`documentdb-local/scripts/`). No Rust, C, or gateway code is added or changed.

**Emitter script.** A single new helper script (e.g.
`documentdb-local/scripts/scarf_telemetry.sh`) contains all of:

- Reading and validating configuration from the environment
  (`SCARF_ANALYTICS_ENABLED`, `SCARF_TELEMETRY_ENDPOINT`,
  `SCARF_HEARTBEAT_INTERVAL_S`) and honoring `DO_NOT_TRACK` /
  `SCARF_NO_ANALYTICS`, which always win.
- Resolving host attributes once: `version` from `/version.txt`, `os` from
  `uname -s`, `arch` from `uname -m`, `db_system` = `documentdb`.
- Sending the one-time `emulator_launch` event, then looping to send an
  `emulator_heartbeat` event every `SCARF_HEARTBEAT_INTERVAL_S` seconds.
- Each send is a single fire-and-forget `curl` GET with a short timeout
  (`--max-time 3`), backgrounded so it never blocks startup or serving.

**Wiring.** `emulator_entrypoint.sh` starts the emitter as a background process
after the gateway is confirmed ready, and adds its PID to the existing `cleanup`
trap so it is terminated on container shutdown alongside the other background
processes. When analytics is disabled (default is on) or opted out, the emitter
script exits immediately and no background loop is started.

**Fire-and-forget safety.** Every request is a backgrounded `curl` with a
3-second timeout; all output and errors are discarded (redirected to
`/dev/null`) and logged at most at debug level. A slow, unreachable, blocked, or
non-existent telemetry endpoint has **no effect** on PostgreSQL, the gateway, or
client request latency.

### API Changes

- No changes to any user-facing database API, wire protocol, or UDFs.
- No changes to the OSS gateway (`pg_documentdb_gw`) or its public Rust API.
- The only additions are container-level: new entrypoint flags
  (`--usage-analytics [true|false]` / `--disable-usage-analytics`) and new
  environment variables consumed by the `documentdb-local` scripts.

### Database Schema Changes

None.

### Configuration Changes

- New `documentdb-local` entrypoint flags `--usage-analytics [true|false]` and
  `--disable-usage-analytics` (analytics is on by default; either the `false`
  form or the disable flag turns it off).
- New environment variables consumed by the entrypoint scripts:
  `SCARF_ANALYTICS_ENABLED`, `SCARF_TELEMETRY_ENDPOINT`,
  `SCARF_HEARTBEAT_INTERVAL_S`.
- Honors existing/standard `DO_NOT_TRACK` and `SCARF_NO_ANALYTICS`, which always
  win over the default-on behavior.
- No new build/runtime dependency: the emitter uses `curl`, which is already
  present in the `documentdb-local` image.

### Dependency and Build Impact

- No new library dependencies. The emitter is a shell script that uses `curl`
  (already in the `documentdb-local` image) to make plain HTTPS GET requests to
  the Scarf endpoint.
- No change to the gateway workspace, its `Cargo.toml`, or any compiled binary.
- No change to build tooling; only new scripts are added under
  `documentdb-local/scripts/` and referenced from `emulator_entrypoint.sh`.

### Cost

- **Ingestion / event volume:** free. Scarf does not charge for events,
  telemetry volume, or download traffic, at any volume — this covers both the
  runtime launch/summary events and the container pull tracking.
- **Included free tier (Starter):** unlimited packages, unlimited download
  tracking, unlimited seats, a rolling ~3-month data window, plus a small
  monthly allotment of "Company Unlocks" and "Runs."
- **Optional paid consumption (not required for adoption numbers):**
  - *Company Unlocks* — to reveal the specific named company behind traffic
    (tiered, ~$3 each at low volume; a few free per month).
  - *Runs* — automated workflows such as exports, API calls, scheduled CRM
    syncs (tiered, ~$0.60 each at low volume; a small number free per month).
  - *Annual tiers* (e.g., higher committed volumes, longer data retention, raw
    data feeds) exist but are unnecessary for basic adoption reporting.
- **Net:** producing the OSS adoption numbers this RFC targets costs **$0**.
  Spend is only incurred if the project later opts into enrichment (which
  company) or automated exports.
- Worth evaluating: Scarf's Foundation-Backed Projects program, which may add
  free/discounted allowances.

### Testing Strategy

- **Script unit tests:** the emitter script resolves configuration correctly —
  default-enabled; disabled via `SCARF_ANALYTICS_ENABLED=false` or
  `--disable-usage-analytics`; opt-out (`DO_NOT_TRACK` / `SCARF_NO_ANALYTICS`)
  overrides an explicit enable; endpoint default vs. override; host attributes
  are populated from `/version.txt` and `uname`.
- **Integration test** (extending the existing container test harness in
  `documentdb-local/scripts/documentdb_local_tests/test_image.py`, which already
  exercises telemetry-endpoint behavior): with the default configuration pointed
  at a local HTTP sink, assert an `emulator_launch` event on startup and an
  `emulator_heartbeat` within one interval; assert **no** events are emitted
  when disabled (`SCARF_ANALYTICS_ENABLED=false`) or when `DO_NOT_TRACK=1`.
- **Privacy assertion:** verify emitted payloads contain only the fixed host
  attributes and none of: database name, collection name, user name, document
  content.
- **No-regression assertion:** confirm the OSS gateway build and its tests are
  unchanged (no gateway sources touched).

### Migration Path

- **Additive, but changes default behavior.** Usage analytics is on by default,
  so upgrading to a release that includes it will begin emitting launch +
  heartbeat events from `documentdb-local` unless the operator opts out. The OSS
  gateway is byte-for-byte unchanged. This default-on change should be called
  out prominently in the release notes.
- **Rollout of download tracking** requires updating the documented `docker
  pull` command to the Scarf domain. This should be done under an official
  DocumentDB-owned Scarf domain; the image path after the domain must exactly
  match the registry path (a Scarf/OCI requirement).
- **Rollback / opt-out:** disable via env/flag
  (`SCARF_ANALYTICS_ENABLED=false`, `--disable-usage-analytics`,
  `DO_NOT_TRACK=1`, or `SCARF_NO_ANALYTICS=1`), and revert the documented pull
  command to the direct registry URL. No data migration.

### Documentation Updates

- New `TELEMETRY.md` (documentdb-local) describing, in full: the two separate
  systems, the exact two events and every field, what is never collected, all
  configuration/opt-out controls, that it applies only to `documentdb-local`
  (not the OSS gateway), and design guarantees.
- README: note usage analytics is on by default (opt-out) and scoped to
  `documentdb-local`, show how to opt out, link to `TELEMETRY.md`; and (at
  rollout) present the Scarf-fronted pull command for download tracking.
- CONTRIBUTING/SECURITY as needed to reference the telemetry policy.

---

## Implementation Tracking

*This section SHALL be populated during the Implementation phase.*

### Implementation PRs

- [ ] PR #XXX: Add `documentdb-local/scripts/scarf_telemetry.sh` (config resolution, launch + heartbeat emitter)
- [ ] PR #XXX: Wire the emitter into `emulator_entrypoint.sh` (startup + cleanup trap) and add the `--usage-analytics` / `--disable-usage-analytics` flags (default on)
- [ ] PR #XXX: Extend `documentdb_local_tests/test_image.py` with launch/heartbeat and opt-out assertions
- [ ] PR #XXX: Add `TELEMETRY.md` and README/CONTRIBUTING updates
- [ ] PR #XXX: Register official DocumentDB Scarf domain; update documented pull command

### Status Updates

**2026-07-29:** RFC drafted.

**2026-09-04:** Revised to scope runtime telemetry to the `documentdb-local`
entrypoint scripts only. The OSS gateway (`pg_documentdb_gw`) is explicitly out
of scope because it runs in production (including hosted pgmongo); no gateway
code, dependencies, or metrics are changed. Runtime telemetry is now a
launch + heartbeat emitter shell script; the earlier gateway-instrumented
document-throughput summary and identifier-hashing changes were removed. Also
changed the default to **on (opt-out)** so adoption numbers reflect real usage;
the standard opt-out controls always win.

### Open Questions

- [ ] **Official Scarf organization/domain.** Who owns the
      `documentdb.gateway.scarf.sh` domain and the Event Collection package?
      This must be an org-owned account (not a personal one) before release.
- [ ] **Default heartbeat interval.** Is hourly the right cadence, or should the
      first release use a longer interval (e.g., daily) to minimize traffic?
- [ ] **Enablement policy.** This RFC assumes **on by default (opt-out)** with a
      prominent first-run notice and documented opt-out. Confirm this is
      acceptable to the TSC, and finalize the wording/placement of the first-run
      notice.
- [ ] **Namespace consistency.** The image is published under more than one
      registry namespace; download tracking must front whichever path the
      README advertises (or track multiple).
- [ ] **Foundation program.** Does DocumentDB qualify for Scarf's
      Foundation-Backed Projects allowances?

### Implementation Notes

- **Decision [2026-09-04]: Scope runtime telemetry to `documentdb-local`; do not
  touch the OSS gateway.**
  - **Context:** The OSS gateway (`pg_documentdb_gw`) runs in production
    environments (including hosted pgmongo). Emitting adoption telemetry from the
    production request path is inappropriate and risky. `documentdb-local` is the
    artifact actually distributed for adoption, so telemetry belongs in its
    entrypoint scripts.
  - **Result:** No gateway code, dependencies (`reqwest`), or OTLP metrics are
    changed. The emitter is a shell script using `curl`.
  - **Alternatives:** Instrumenting the gateway with in-process counters
    (rejected: leaks adoption telemetry into production and couples the two
    concerns).

- **Decision [2026-09-04]: Launch + heartbeat instead of a document-throughput
  summary.**
  - **Context:** The entrypoint script has no visibility into the gateway's
    request path, so per-operation document counts are not available without
    instrumenting the gateway (explicitly out of scope).
  - **Result:** Runtime telemetry sends a one-time launch event and periodic
    heartbeats carrying only fixed host attributes — enough to count running
    deployments by version/platform, with zero request-path data.

- **Decision [2026-07-29]: Separate Scarf emitter from OTLP.**
  - **Context:** OTLP metrics are high-frequency operational data for operators;
    Scarf events are coarse adoption signals for maintainers. Scarf accepts only
    HTTP, not OTLP/gRPC.
  - **Alternatives:** Bridging OTLP metrics into Scarf (rejected: wrong shape,
    high cardinality, values become strings in Scarf, and it would leak
    user-defined labels).

- **Decision [2026-07-29]: Off by default, opt-in, fire-and-forget.**
  - **Context:** Runtime telemetry from a user's process must never surprise,
    block, or fail the workload.
  - **Result:** Disabled unless explicitly enabled; `DO_NOT_TRACK` /
    `SCARF_NO_ANALYTICS` always win; 3-second timeout; all errors ignored.
  - **Superseded by** the 2026-09-04 decision below.

- **Decision [2026-09-04]: On by default (opt-out), fire-and-forget.**
  - **Context:** Opt-in telemetry captures only a small, self-selected fraction
    of deployments, which undercounts adoption. Because the payload contains
    only fixed host attributes (no user data), default-on is low-risk.
  - **Result:** Enabled by default; disabled via `SCARF_ANALYTICS_ENABLED=false`
    or `--disable-usage-analytics`; the standard opt-out (`DO_NOT_TRACK` /
    `SCARF_NO_ANALYTICS`) always wins; 3-second timeout; all errors ignored.
  - **Supersedes:** the 2026-07-29 off-by-default/opt-in decision.
  - **Mitigations:** prominent first-run notice, documented opt-out in README
    and `TELEMETRY.md`, and a release-note callout of the default-on behavior.
