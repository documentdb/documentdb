---
rfc: 0007
title: "Guidance for Onboarding Statistical Views"
status: Draft
owner: "@WentingWu666666"
issue: NA
discussion: NA
version-target: NA
implementations: NA

---

# RFC-0007: Guidance for Onboarding Statistical Views

## Problem

DocumentDB currently lacks a standardized, well-defined process for contributors to onboard new statistical views. 
While contributors may want to expose various runtime, performance, or usage insights through SQL views, there is no consistent guidance for:
- How views should be named and organized  
- Where SQL definitions should live in the repository  
- How columns and units should be defined  
- How permissions should be handled  
- How statistics collection should be enabled/disabled safely  

This creates friction for both contributors and reviewers:
- Contributors must guess conventions or invent their own patterns.
- Reviewers lack a consistent set of rules to evaluate submissions.
- Inconsistencies across views make them harder to discover, document, and maintain.

Without this guidance, statistical views may become fragmented, inconsistent, or unsafe (e.g., unexpected overhead, unclear reset behavior, or overly broad permissions).

This RFC proposes a set of conventions and rules that define *how* statistical views should be added, not *which* specific views must exist.

### Who is impacted

- Contributors adding new statistical or observability-related functionality  
- Maintainers reviewing and approving contributions  
- Users who rely on DocumentDB system statistics for monitoring and troubleshooting  

### Success criteria

- A clear, documented set of rules for adding new statistical views  
- Consistent naming, schema placement, and column conventions  
- Controlled permissions and predictable reset behavior  
- Minimal friction for contributors to follow the pattern  

### Non-goals

- This RFC does **not** design or implement any specific statistical view.
- This RFC does **not** replace existing PostgreSQL statistical views.

---

## Approach

The proposed solution is to define and document a standard onboarding pattern for statistical views in DocumentDB, 
inspired by established conventions in PostgreSQL (e.g., `pg_stat_*` views) and widely-used extensions (e.g., Citus).

---

## Detailed Design

### API Changes

#### 1. Naming Convention
**View name**: documentdb_stat_<scope>
Examples:
- `documentdb_stat_collections`
- `documentdb_stat_queries`
- `documentdb_stat_connections`

**Column naming**
- Columns representing a value must end with a unit suffix:
  - `_count`
  - `_seconds`
  - `_milliseconds`
  - `_bytes`
  - `_percent`

- Columns representing dimensions (e.g., name, database, collection, user) should **not** use a suffix.

TBD

### Configuration Changes

Since collecting statistics introduces overhead, each category of statistical data should be gated behind a configuration flag.

Pattern: documentdb_track_<scope>

Examples:

- `documentdb_track_queries`
- `documentdb_track_connections`
- `documentdb_track_collections`

Default value: true

These parameters should be configurable via `postgresql.conf` and/or runtime configuration where supported.

When the flag is set to `false`:
- Statistics collection should stop
- The corresponding view should return empty or zeroed data (not fail)


### Documentation Updates

Update the following documentation to include:

- List of statistical views
- Column descriptions and units
- Reset functions (if any)
- Related configuration parameters

Target location:
https://github.com/documentdb/documentdb.github.io
/articles/postgresql/stats.md

Each new statistical view must include:
- Description of purpose
- Example query
- Sample output

---

## Implementation Tracking

NA

### Status Updates

NA

### Open Questions

NA

### Implementation Notes

NA