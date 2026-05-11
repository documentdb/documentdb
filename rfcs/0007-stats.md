---
rfc: 0007
title: "Guidance for Onboarding Statistics"
status: Draft
owner: "@WentingWu666666"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
---

# RFC-0007: Guidance for Onboarding Statistics

## Problem

DocumentDB currently lacks a standardized, well-defined process for contributors to onboard new statistics. While contributors may want to expose various runtime, performance, or usage insights, there is no consistent guidance for:

- How statistics should be exposed
- How statistics collection should be enabled or disabled safely

This creates friction for both contributors and reviewers:

- Contributors must guess conventions or invent their own patterns.
- Reviewers lack a consistent set of rules to evaluate submissions.
- Inconsistencies across statistics make them harder to discover, document, and maintain.

Without this guidance, statistics may become fragmented, inconsistent, or unsafe (for example: unexpected overhead, unclear reset behavior, or overly broad permissions).

This RFC proposes a set of conventions and rules that define **how** statistics should be added, not **which** specific statistics must exist.

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

The approach is inspired by established conventions in PostgreSQL (e.g., `pg_stat_*` views) and widely-used extensions (e.g., Citus).

In DocumentDB, statistics should be exposed through **views**.

- Views may be backed directly by SQL statements.
- Views may also be backed by one or more underlying helper functions when the logic is complex or requires internal state.


This RFC defines:
- Naming conventions for views and functions
- Standard patterns for permissions
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

1. The helper signature is not part of the public stats API; granting EXECUTE to PUBLIC would freeze it as ABI.
2. Any row filtering or redaction performed by the view (for example, hiding query text from non-privileged roles, mirroring `pg_stat_activity`) is bypassable if callers can reach the helper directly.

Where a helper must read state the caller cannot reach (for example, a shared-memory hash table holding per-query timings), declare it as `SECURITY DEFINER` so it executes with the function owner's privileges, and **always pin the search path** to defeat search-path attacks:

```sql
CREATE FUNCTION __API_SCHEMA_INTERNAL__.documentdb_stat_get_<scope>(...)
RETURNS SETOF ...
LANGUAGE c
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS '$libdir/pg_documentdb', 'documentdb_stat_get_<scope>';
```

`SECURITY DEFINER` functions must not interpolate user-controlled strings into SQL.

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

EXECUTE is revoked from `PUBLIC` and granted to the existing extension admin role, mirroring the pattern in `pg_documentdb/sql/rbac/extension_admin_setup--0.10-0.sql`:

```sql
REVOKE EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>() TO __API_ADMIN_ROLE__;
```

Superusers always bypass ACLs and can call any reset function. Non-superuser operators who need reset capability must be granted membership in `__API_ADMIN_ROLE__` (or be granted EXECUTE explicitly on a per-function basis if more granular control is desired).

This model — public SELECT on the view, no PUBLIC EXECUTE on helpers, named-role EXECUTE on reset — matches how `pg_stat_statements` and Citus's `citus_stat_*` family expose statistics. Any deviation (for example, a stat that genuinely needs PUBLIC EXECUTE on its helper) must be explicitly justified in the contributing PR.


#### Configuration Changes

Since collecting statistics introduces overhead, each category of statistical data should be gated behind a configuration flag.

**Naming pattern**
```
documentdb_track_<scope>
```

Examples:

- `documentdb_track_queries`
- `documentdb_track_connections`
- `documentdb_track_collections`

Default value: `true` (see Open Questions — whether to default to `true` or `false` is unresolved).

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
- A test that exercises the `documentdb_track_<scope>` flag in both states and asserts the view returns an empty set when the flag is `false`.
- For views with cumulative counters: a test that exercises the reset function and asserts `stats_reset` advances.
- A permissions test that asserts `SELECT` on the view succeeds for an unprivileged role and `EXECUTE` on the reset function fails for an unprivileged role.

### Migration Path

This RFC is purely additive and applies only to **new** statistics. Pre-existing statistics in DocumentDB are not retroactively required to follow these conventions; they may be migrated opportunistically when touched. No user-visible upgrade or rollback steps are required by this RFC itself.

### Contributor Checklist: How to add a new statistic

When adding a new statistic under this RFC, a contributor should:

1. **Pick a scope name.** Lowercase, singular-or-plural noun matching the category (e.g., `queries`, `connections`). Confirm it does not collide with an existing `documentdb_stat_*` view or with PostgreSQL's `pg_stat_*` namespace.
2. **Register the GUC.** Add `documentdb.track_<scope>` (default per the Open Questions decision) in the C code that registers extension GUCs, and reference it from the collection path so disabling the flag halts collection.
3. **Add the SQL definitions** under `pg_documentdb/sql/udfs/stats/`:
   - Update `stats--latest.sql` with the view, optional helper(s), and optional reset function.
   - Add a `stats--<from>-<to>.sql` upgrade script for the version bump.
4. **Apply the canonical grants** (see "Permissions for helpers" and "Permissions for reset functions"):
   - `GRANT SELECT ON ... TO PUBLIC;` for the view.
   - No grant to `PUBLIC` on helper functions; use `SECURITY DEFINER` with `SET search_path = pg_catalog, pg_temp` if the helper needs privileged state.
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

- **Default value of `documentdb_track_<scope>`.** This RFC currently proposes `true` for discoverability, but that conflicts with the "minimal overhead" framing in the Problem section and diverges from `pg_stat_statements`-style extensions that default to off. Decide before moving Draft → Proposed.
- **Tracking issue and discussion links.** `issue` is currently a `TBD` placeholder; file a tracking issue and update the frontmatter before moving Draft → Proposed.

### Implementation Notes

NA
