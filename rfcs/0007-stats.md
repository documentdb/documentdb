---
rfc: 0007
title: "Guidance for Onboarding Statistics"
status: Draft
owner: "@WentingWu666666"
issue: NA
discussion: NA
version-target: NA
implementations: NA

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

### Views
Statistcs will be exposed through views.

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

- `stats_reset` column is required if the view contains cumulative counters. This column indicates the timestamp of the last reset.

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

All statistical views must be defined in the following location:
```
pg_documentdb/sql/stats/stats--<version>.sql
```

### Helper Functions
If a view is backed by one or more helper functions, those functions must follow this naming pattern:
```
__API_CATALOG_SCHEMA__.documentdb_stat_get_<scope>
```

By default, helper functions must be executable by all users:
```
GRANT EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_get_<scope>() TO PUBLIC;
```

#### Reset functions (for cumulative counters)

If a view contains cumulative counters that may need to be reset, a reset function must be provided.

**Naming pattern**
```
__API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>
```
By default, this function is restricted to superusers:
```
REVOKE EXECUTE ON FUNCTION __API_CATALOG_SCHEMA__.documentdb_stat_reset_<scope>() FROM public;
```
Other roles may be explicitly granted permission as needed.


### Configuration Changes

Since collecting statistics introduces overhead, each category of statistical data should be gated behind a configuration flag.

**Naming pattern**
```
documentdb_track_<scope>
```

Examples:

- `documentdb_track_queries`
- `documentdb_track_connections`
- `documentdb_track_collections`

Default value: `true`

These parameters should be configurable via `postgresql.conf` and/or runtime configuration where supported.

When the flag is set to `false`:
- Statistics collection should stop
- The corresponding view should return empty or zeroed data (not fail)


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

---

## Implementation Tracking

NA

### Status Updates

NA

### Open Questions

NA

### Implementation Notes

NA