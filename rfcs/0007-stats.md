---
rfc: 0007
title: "Guidance for Onboarding Statistics"
status: Draft
owner: "@WentingWu666666"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
---

# RFC-0007: Guidance for Onboarding Statistics

## Problem

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

PostgreSQL's own `pg_stat_*` family and extensions like `pg_stat_statements` demonstrate that a small, consistent set of conventions — standard naming, a GUC (Grand Unified Configuration) parameter to gate collection, public `SELECT` on views, restricted `EXECUTE` on reset functions — makes statistics predictable and maintainable at scale.

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
- This RFC does **not** cover statistics exposed through the MongoDB wire protocol (e.g., `collStats`, `dbStats`). Those follow MongoDB API compatibility conventions. This RFC covers only **extension-defined statistics** consumed via SQL by operators and monitoring tools.

---

## Approach

The approach is inspired by established conventions in PostgreSQL (e.g., `pg_stat_*` views) and widely-used extensions (e.g., `pg_stat_statements`).

In DocumentDB, statistics should be exposed through **views** — literal PostgreSQL `CREATE VIEW` objects that users can `SELECT` from, not an abstract concept. Each view provides a stable, tabular interface to a category of statistics.

- Views may be backed directly by SQL statements.
- Views may also be backed by one or more underlying helper functions when the logic is complex or requires internal state (e.g., reading from shared memory).

The **permission model** is straightforward:

- **Read**: any connected role can query statistics — views are granted `SELECT … TO PUBLIC`.
- **Reset**: only the extension admin role (`__API_ADMIN_ROLE__`) can clear cumulative counters via reset functions. `EXECUTE` is revoked from `PUBLIC`.
- **Helpers**: not granted to `PUBLIC` — the view is the API boundary.

This model matches how `pg_stat_statements` exposes statistics. Any deviation (for example, a stat that genuinely needs PUBLIC EXECUTE on its helper) must be explicitly justified in the contributing PR.

This RFC defines:
- Naming conventions for views and functions
- Standard patterns for permissions (as summarized above)
- Configuration switches to enable/disable collection
- Documentation requirements for each statistic

The goal is to provide a predictable and maintainable pattern that aligns with familiar PostgreSQL design.

---

## Detailed Design

### Technical Details

This RFC defines conventions only; no new code paths or data structures are introduced. Each statistic implemented under these conventions will have its own technical design.

### API Changes

The naming patterns below use build-system macros that expand to real PostgreSQL schema and role names at install time:

- `__API_CATALOG_SCHEMA__` — the public-facing schema where views and reset functions are created.
- `__API_SCHEMA_INTERNAL__` — the internal schema for implementation-detail functions (not part of the public API).
- `__API_ADMIN_ROLE__` — the extension's admin role, used to restrict destructive operations like counter resets.

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
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.documentdb_stat_get_<scope>(...)
RETURNS SETOF ...
LANGUAGE c VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$documentdb_stat_get_<scope>$$;
```

#### Reset Functions

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

### Configuration Changes

Each category of statistical data should be gated behind a GUC flag to control collection overhead.

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


### Documentation Updates

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

### Performance Considerations

Contributors adding new statistics must consider the impact on frequently executed code paths (e.g., per-query, per-operation):

1. **Collection overhead**: Use lock-free mechanisms (atomic increments, per-backend buffers) for counters updated in the query execution path. Never hold a lock to update a statistic.

2. **GUC as a kill switch**: When `documentdb.track_<scope>` is `false`, collection must stop entirely — not just hide output. Zero overhead when disabled.

3. **Memory budget**: Shared-memory-backed stats should declare their memory footprint in the PR description. Prefer fixed-size allocations (bounded by `MaxBackends` or a compile-time constant).

4. **Validation**: PRs adding a new statistic should include a before/after benchmark demonstrating negligible throughput regression with the stat enabled.

### Contributor Checklist: How to add a new statistic

This section walks through every step a contributor must complete when adding a new statistic. Code examples use a hypothetical `io` scope for illustration.

#### 1. Pick a scope name

Choose a lowercase, singular-or-plural noun matching the category (e.g., `queries`, `connections`, `io`). Confirm it does not collide with an existing `documentdb_stat_*` view or with PostgreSQL's `pg_stat_*` namespace.

#### 2. Register the GUC

In `pg_documentdb/src/configs/system_configs.c`, add a boolean GUC to gate collection. Choose the default per the rule of thumb in "Configuration Changes."

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

#### 3. Add the SQL definitions

Add the view, optional helper(s), and optional reset function under `pg_documentdb/sql/udfs/stats/`:

**Helper function** (in `stats--latest.sql`):

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
LANGUAGE c VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$documentdb_stat_get_io$$;

-- Helper is NOT granted to PUBLIC.
-- The view owner has the privileges needed to call it.
```

**View:**

```sql
CREATE OR REPLACE VIEW __API_CATALOG_SCHEMA__.documentdb_stat_io AS
SELECT database,
       read_count,        -- value (with _count suffix)
       write_count,       -- value (with _count suffix)
       read_bytes,        -- value (with _bytes suffix)
       write_bytes,       -- value (with _bytes suffix)
       stats_reset        -- timestamp of last reset (exempt from suffix rule)
FROM   __API_SCHEMA_INTERNAL__.documentdb_stat_get_io()
WHERE  current_setting(__SINGLE_QUOTED_STRING__(__API_GUC_PREFIX__) || '.track_io')::bool;
-- Returns empty result set when tracking is off.
```

**Reset function** (if the view has cumulative counters):

```sql
CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_io()
RETURNS void
LANGUAGE c VOLATILE PARALLEL UNSAFE
AS 'MODULE_PATHNAME', $$documentdb_stat_reset_io$$;
```

#### 4. Apply the canonical grants

Place these alongside the definitions in the same stats SQL file:

```sql
-- View: readable by all
GRANT SELECT ON __API_CATALOG_SCHEMA__.documentdb_stat_io TO PUBLIC;

-- Reset: restricted to admin role
REVOKE EXECUTE ON FUNCTION
    __API_CATALOG_SCHEMA__.documentdb_stat_reset_io() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION
    __API_CATALOG_SCHEMA__.documentdb_stat_reset_io() TO __API_ADMIN_ROLE__;
```

#### 5. Add the upgrade script

Add `pg_documentdb/sql/udfs/stats/stats--<from>-<to>.sql` (e.g., `stats--0.111-0--0.112-0.sql`) containing the same definitions for the version bump.

#### 6. Add tests

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

#### 7. Update documentation

Open a companion PR against `https://github.com/documentdb/documentdb.github.io` adding an entry to `/articles/postgresql/stats.md` covering: description, column definitions with units, example query and output, related GUC (`documentdb.track_io`), and the reset function.

#### 8. Validate performance

Run a before/after benchmark demonstrating negligible throughput regression with the stat enabled. Ensure collection uses lock-free mechanisms and the GUC fully disables collection (zero overhead when off). See "Performance Considerations" for details.

#### 9. Justify any deviations

If your statistic deviates from the canonical permission or path conventions, explain why in the PR description so reviewers can evaluate it explicitly.

---

## Implementation Tracking

NA

### Status Updates

NA

### Open Questions

NA

### Implementation Notes

NA
