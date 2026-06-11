---
rfc: 0007
title: "Guidance for Onboarding Statistics"
status: Draft
owner: "@WentingWu666666"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
---

# RFC-0007: Guidance for Onboarding Statistics

## Background & Motivation

### What exists today

DocumentDB exposes diagnostic commands such as `coll_stats`, `db_stats`, `index_stats`, and `current_op`. These exist to provide **MongoDB API compatibility** — they return BSON documents and mirror the behavior of their MongoDB counterparts. They are not designed as a reusable pattern for exposing new PostgreSQL-native statistics.

Outside of these MongoDB-compatible commands, DocumentDB has **no mechanism** for exposing internal runtime, performance, or usage statistics as PostgreSQL-native objects. There are currently:

- **No `SELECT`-able views** — no tabular interface comparable to PostgreSQL's `pg_stat_*` views.
- **No configuration flags** to gate statistics collection — no way to control overhead.
- **No reset functions** for cumulative counters.
- **No consistent permission policy** for who can read statistics versus who can reset them.

### Why conventions matter now

As DocumentDB grows, contributors will need to add new statistics — query performance counters, connection usage, cache hit rates, and similar observability data. Without a shared convention:

- Contributors must guess patterns or invent their own, leading to inconsistent APIs.
- Reviewers lack a baseline to evaluate whether a new statistic follows a safe and discoverable pattern.
- Over time, inconsistencies accumulate and make the statistics surface harder to discover, document, and maintain.

PostgreSQL's own `pg_stat_*` family and extensions like `pg_stat_statements` demonstrate that a small, consistent set of conventions — standard naming, a GUC to gate collection, public `SELECT` on views, restricted `EXECUTE` on reset functions — makes statistics predictable and maintainable at scale.

### What this RFC does

This RFC establishes that baseline for DocumentDB. It defines **how** statistics should be added — not **which** specific statistics must exist. The goal is a set of rules that make new statistics **predictable, discoverable, and safe by default**, so that a contributor (or even an AI code-generation tool) can follow the pattern end-to-end without tribal knowledge.

### Who is impacted

- Contributors adding new statistical or observability-related functionality
- Maintainers reviewing and approving contributions
- Users who rely on DocumentDB system statistics for monitoring and troubleshooting

### Success criteria

- A clear, documented set of rules for adding new statistics
- Consistent naming and API patterns for statistics
- Controlled permissions and predictable reset behavior
- Minimal friction for contributors to follow the pattern

### Non-goals

- This RFC does **not** design or implement any specific statistics.
- This RFC does **not** replace or modify existing PostgreSQL statistics.
- This RFC does **not** address using statistics for query planning or optimization. The focus is solely on exposability and monitoring.

---

## Approach

The approach is inspired by established conventions in PostgreSQL (e.g., `pg_stat_*` views) and widely-used extensions (e.g., `pg_stat_statements`).

In DocumentDB, statistics should be exposed through **views** — literal PostgreSQL `CREATE VIEW` objects that users can `SELECT` from, not an abstract concept. Each view provides a stable, tabular interface to a category of statistics.

- Views may be backed directly by SQL statements.
- Views may also be backed by one or more underlying helper functions when the logic is complex or requires internal state (e.g., reading from shared memory).

The **permission model** is straightforward:

- **Read**: any connected role can query statistics — views are granted `SELECT … TO PUBLIC`.
- **Reset**: only the extension admin role (`__API_ADMIN_ROLE__`) can clear cumulative counters via reset functions. `EXECUTE` is revoked from `PUBLIC`.

This RFC defines:
- Naming conventions for views and functions
- Standard patterns for permissions (as summarized above)
- Configuration switches to enable/disable collection
- Documentation requirements for each statistic

The goal is to provide a predictable and maintainable pattern that aligns with familiar PostgreSQL design.

---

## Detailed Design

### API Changes

#### Views
Statistics will be exposed through views.

**View naming pattern**
```
__API_CATALOG_SCHEMA__.documentdb_stat_<scope>
```

Where `<scope>` describes the category of statistics being exposed. Examples include:
- `queries`
- `connections`
- `collections`
- `indexes`

**Column naming in views**
- Columns representing a **value** must end with a unit suffix:
  - `_count`
  - `_seconds`
  - `_milliseconds`
  - `_bytes`
  - `_percent`

- Columns representing **dimensions** (e.g., name, database, collection, user) should **not** use a suffix.

- Metadata columns that carry a timestamp are exempt from the unit-suffix rule. Specifically, `stats_reset` is required if the view contains cumulative counters and indicates the timestamp of the last reset. Other timestamp-typed metadata columns (e.g., `last_updated`, `first_seen`) are likewise exempt.

**Example** (for illustration purposes only, not an actual view):
```sql
CREATE VIEW documentdb_stat_queries AS
SELECT
    database,           -- dimension (no suffix)
    collection,         -- dimension (no suffix)
    user_name,          -- dimension (no suffix)
    query_count,        -- value (with _count suffix)
    total_seconds,      -- value (with _seconds suffix)
    avg_milliseconds,   -- value (with _milliseconds suffix)
    cache_hit_percent,  -- value (with _percent suffix)
    stats_reset         -- timestamp of last reset
FROM ...
```

By default, all statistical views are readable by all users:
```
GRANT SELECT ON __API_CATALOG_SCHEMA__.documentdb_stat_<scope> TO PUBLIC;
```

All statistical views must be defined under `pg_documentdb/sql/`, following the extension's existing versioned-SQL convention used elsewhere in the tree (see `pg_documentdb/sql/udfs/...` for examples):

- A `stats--latest.sql` file containing the current definition.
- One `stats--<from>-<to>.sql` upgrade script per version bump that adds or modifies a stat (for example `stats--0.110-0--0.111-0.sql`).

Recommended location:

```
pg_documentdb/sql/udfs/stats/stats--latest.sql
pg_documentdb/sql/udfs/stats/stats--<from>-<to>.sql
```

#### Helper Functions
If a view is backed by helper functions, those functions must follow this naming pattern:

- Single helper per scope:
  ```
  __API_SCHEMA_INTERNAL__.documentdb_stat_get_<scope>
  ```
- Multiple helpers per scope (when the view is composed from several functions): add an `<aspect>` suffix:
  ```
  __API_SCHEMA_INTERNAL__.documentdb_stat_get_<scope>_<aspect>
  ```
  Examples: `documentdb_stat_get_queries_summary`, `documentdb_stat_get_queries_per_collection`.

Helper functions live in `__API_SCHEMA_INTERNAL__` because they are implementation details of the view, not part of the public stats API. The view (in `__API_CATALOG_SCHEMA__`) is the documented surface; clients should always go through it.

**Permissions for helpers**

By default, helper functions are **not** granted to `PUBLIC`. The view is the policy boundary, and the view's owner has the privileges needed to call the helper. Two reasons to keep helpers private:

1. The helper signature is not part of the public stats API; granting EXECUTE to PUBLIC would freeze it as a public API contract.
2. Any row filtering or redaction performed by the view (for example, hiding query text from non-privileged roles, mirroring `pg_stat_activity`) is bypassable if callers can reach the helper directly.

```sql
CREATE FUNCTION __API_SCHEMA_INTERNAL__.documentdb_stat_get_<scope>(...)
RETURNS SETOF ...
LANGUAGE c
AS '$libdir/pg_documentdb', 'documentdb_stat_get_<scope>';
```

##### Reset functions (for cumulative counters)

If a view contains cumulative counters that may need to be reset, a reset function must be provided.

**Naming pattern**
```
__API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>
```

**Signatures**
- The canonical signature is the no-argument form, which resets all counters for the scope:
  ```
  __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>()
  ```
- Targeted variants may be added with parameters that match the dimension columns of the view, for example:
  ```
  __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>(database text, collection text)
  ```

**Permissions for reset functions**

EXECUTE is revoked from `PUBLIC` and granted to the existing extension admin role (`__API_ADMIN_ROLE__`). These grants should be placed in the stats SQL file alongside the function definition:

```sql
REVOKE EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>() TO __API_ADMIN_ROLE__;
```

Non-superuser operators who need reset capability must be granted membership in `__API_ADMIN_ROLE__` (or be granted EXECUTE explicitly on a per-function basis if more granular control is desired).

#### Permission Model Summary

This model — public SELECT on the view, no PUBLIC EXECUTE on helpers, named-role EXECUTE on reset — matches how `pg_stat_statements` exposes statistics. Any deviation (for example, a stat that genuinely needs PUBLIC EXECUTE on its helper) must be explicitly justified in the contributing PR.


#### Configuration Flags (GUC)

Since collecting statistics introduces overhead, each category of statistical data should be gated behind a configuration flag.

**Naming pattern**
```
documentdb.track_<scope>
```

Examples:

- `documentdb.track_queries`
- `documentdb.track_connections`
- `documentdb.track_collections`

Default value: chosen by the contributor based on the cost/value of the statistic. As a rule of thumb, default to `true` for low-overhead, broadly useful statistics (so they are discoverable out of the box) and to `false` for statistics whose collection is expensive or whose results are only meaningful in targeted investigations (matching the precedent set by `pg_stat_statements`).

These parameters should be configurable via `postgresql.conf` and/or runtime configuration where supported.

When the flag is set to `false`:
- Statistics collection should stop.
- The corresponding view should return an **empty result set** (not fail, and not return zeroed rows). An empty set is unambiguous in dashboards and alerting; zeroed rows can be misread as "the system is healthy."


#### Documentation Updates

The following documentation must be updated when new statistics are added:

**Repository**
```
https://github.com/documentdb/documentdb.github.io
```

**File path**
```
/articles/postgresql/stats.md
```

Each new statistic must include:

- Description of the statistic and its purpose
- Column definitions and units
- Example query
- Example output
- Related configuration parameters
- Reset functions (if applicable)

### Database Schema Changes

This RFC does not introduce data tables. It does add objects across two extension schemas:

- One view per scope in `__API_CATALOG_SCHEMA__` (`documentdb_stat_<scope>`).
- Optional helper functions in `__API_SCHEMA_INTERNAL__` (`documentdb_stat_get_<scope>[_<aspect>]`).
- Optional reset functions in `__API_CATALOG_SCHEMA__` (`documentdb_stat_reset_<scope>`).

Each new statistic is delivered following the extension's existing versioned-SQL convention: a `stats--latest.sql` plus one `stats--<from>-<to>.sql` upgrade script per version bump, located under `pg_documentdb/sql/udfs/stats/`.

### Testing Strategy

Each new statistic added under this RFC should include:

- Unit/regression tests that verify the view's columns, types, and naming conventions.
- A test that exercises the `documentdb.track_<scope>` flag in both states and asserts the view returns an empty set when the flag is `false`.
- For views with cumulative counters: a test that exercises the reset function and asserts `stats_reset` advances.
- A permissions test that asserts `SELECT` on the view succeeds for an unprivileged role and `EXECUTE` on the reset function fails for an unprivileged role.

### Migration Path

This RFC is purely additive and applies only to **new** statistics. Pre-existing statistics in DocumentDB are not retroactively required to follow these conventions; they may be migrated opportunistically when touched. No user-visible upgrade or rollback steps are required by this RFC itself.

### Contributor Checklist: How to add a new statistic

When adding a new statistic under this RFC, a contributor should:

1. **Pick a scope name.** Lowercase, singular-or-plural noun matching the category (e.g., `queries`, `connections`). Confirm it does not collide with an existing `documentdb_stat_*` view or with PostgreSQL's `pg_stat_*` namespace.
2. **Register the GUC.** Add `documentdb.track_<scope>` (default chosen per the rule of thumb in "Configuration Flags (GUC)") in the C code that registers extension GUCs, and reference it from the collection path so disabling the flag halts collection.
3. **Add the SQL definitions** under `pg_documentdb/sql/udfs/stats/`:
   - Update `stats--latest.sql` with the view, optional helper(s), and optional reset function.
   - Add a `stats--<from>-<to>.sql` upgrade script for the version bump.
4. **Apply the canonical grants** (see "Permissions for helpers" and "Permissions for reset functions"):
   - `GRANT SELECT ON ... TO PUBLIC;` for the view.
   - No grant to `PUBLIC` on helper functions.
   - `REVOKE EXECUTE ... FROM PUBLIC;` and `GRANT EXECUTE ... TO __API_ADMIN_ROLE__;` for any reset function.
5. **Add tests** as listed in the Testing Strategy section above (column shape, flag-off behavior, reset behavior, permissions).
6. **Update documentation.** Open a companion PR against `https://github.com/documentdb/documentdb.github.io` adding an entry to `/articles/postgresql/stats.md` with description, column definitions and units, an example query and output, related configuration parameters, and reset functions (if applicable).
7. **Justify any deviation from the canonical permission/path conventions** in the PR description so reviewers can evaluate it explicitly.

---

## Implementation Tracking

NA

### Status Updates

NA

### Open Questions

NA

### Implementation Notes

NA

---

## Appendix A: Worked Example — `documentdb_stat_io`

This appendix shows the complete set of artifacts a contributor would produce when adding a hypothetical I/O statistics scope. The example is **illustrative only** — it does not propose a real statistic. Its purpose is to demonstrate the full pattern end-to-end so that contributors can follow it as a template.

### A.1 — Register the GUC

In `pg_documentdb/src/configs/system_configs.c`, add a boolean GUC to gate collection:

```c
/* Whether to collect I/O statistics. */
bool DocumentDBTrackIO = true;

DefineCustomBoolVariable(
    psprintf("%s.track_io", prefix),
    gettext_noop("Enables collection of I/O statistics."),
    NULL,
    &DocumentDBTrackIO,
    true,                       /* default on — low overhead */
    PGC_SUSET,
    0,
    NULL, NULL, NULL);
```

### A.2 — Helper function

In `pg_documentdb/sql/udfs/stats/stats--latest.sql`, define the internal helper:

```sql
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.documentdb_stat_get_io()
RETURNS TABLE (
    database       text,
    read_count     bigint,
    write_count    bigint,
    read_bytes     bigint,
    write_bytes    bigint,
    stats_reset    timestamptz
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'documentdb_stat_get_io';

-- Helper is NOT granted to PUBLIC.
-- The view owner has the privileges needed to call it.
```

### A.3 — View

```sql
CREATE OR REPLACE VIEW __API_CATALOG_SCHEMA__.documentdb_stat_io AS
SELECT database,
       read_count,        -- value (with _count suffix)
       write_count,       -- value (with _count suffix)
       read_bytes,        -- value (with _bytes suffix)
       write_bytes,       -- value (with _bytes suffix)
       stats_reset        -- timestamp of last reset (exempt from suffix rule)
FROM   __API_SCHEMA_INTERNAL__.documentdb_stat_get_io()
WHERE  current_setting('documentdb.track_io')::bool;
-- Returns empty result set when tracking is off.

GRANT SELECT ON __API_CATALOG_SCHEMA__.documentdb_stat_io TO PUBLIC;
```

### A.4 — Reset function

```sql
CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_io()
RETURNS void
LANGUAGE c
AS 'MODULE_PATHNAME', 'documentdb_stat_reset_io';

REVOKE EXECUTE ON FUNCTION
    __API_CATALOG_SCHEMA__.documentdb_stat_reset_io() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION
    __API_CATALOG_SCHEMA__.documentdb_stat_reset_io() TO __API_ADMIN_ROLE__;
```

### A.5 — Upgrade script

Add `pg_documentdb/sql/udfs/stats/stats--0.111-0--0.112-0.sql` containing the same definitions as above (view, helper, reset, grants) for the version bump.

### A.6 — Tests (sketch)

```sql
-- 1. Column shape
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'documentdb_stat_io'
ORDER  BY ordinal_position;
-- Expect: database (text), read_count (bigint), write_count (bigint),
--         read_bytes (bigint), write_bytes (bigint), stats_reset (timestamptz)

-- 2. Flag off → empty result set
SET documentdb.track_io = false;
SELECT count(*) FROM __API_CATALOG_SCHEMA__.documentdb_stat_io;
-- Expect: 0

-- 3. Reset advances stats_reset
SELECT stats_reset AS before FROM __API_CATALOG_SCHEMA__.documentdb_stat_io LIMIT 1;
SELECT __API_CATALOG_SCHEMA__.documentdb_stat_reset_io();
SELECT stats_reset AS after FROM __API_CATALOG_SCHEMA__.documentdb_stat_io LIMIT 1;
-- Expect: after > before

-- 4. Permission: unprivileged role can SELECT but cannot reset
SET ROLE unprivileged_user;
SELECT * FROM __API_CATALOG_SCHEMA__.documentdb_stat_io;   -- OK
SELECT __API_CATALOG_SCHEMA__.documentdb_stat_reset_io();  -- ERROR: permission denied
```

### A.7 — Documentation

Open a companion PR against `https://github.com/documentdb/documentdb.github.io` adding an entry to `/articles/postgresql/stats.md` covering: description, column definitions with units, example query and output, related GUC (`documentdb.track_io`), and the reset function.
