# AGENTS.md — DocumentDB

Project context for AI coding agents. See [CONTRIBUTING.md](./CONTRIBUTING.md) for
contribution rules including AI disclosure requirements.

## Overview

DocumentDB is a MongoDB-compatible document database built as PostgreSQL extensions.
It adds BSON datatype support and a MongoDB wire protocol gateway to PostgreSQL.

- **Repo:** https://github.com/documentdb/documentdb
- **Docs:** https://documentdb.io
- **License:** MIT
- **Discord:** https://discord.gg/vH7bYu524D

## Project Structure

| Component | Language | Description |
|-----------|----------|-------------|
| `pg_documentdb_core/` | C | Core extension: BSON datatypes, I/O, query planner integration. No dependencies. Tests: `pg_documentdb_core/src/test/regress/` |
| `pg_documentdb/` | C | Main extension: CRUD API, aggregation pipeline, indexing, auth, geospatial, vector search. Depends on `documentdb_core`, `pg_cron`, `tsm_system_rows`, `vector`, `postgis`. Tests: `pg_documentdb/src/test/regress/` |
| `pg_documentdb_extended_rum/` | C | RUM index support for document search. Tests: `pg_documentdb/src/test/extended_rum_tests/` |
| `pg_documentdb_gw/` | Rust | Gateway workspace: `documentdb_gateway_core` (shared library for protocol translation, auth, connection handling) + `documentdb_gateway` (standalone binary). Translates MongoDB wire protocol to PostgreSQL queries. Tests: `pg_documentdb_gw/documentdb_tests/` (integration) + inline unit tests |
| `pg_documentdb_gw_host/` | Rust | Pgrx extension that runs `documentdb_gateway_core` as a PostgreSQL background worker (alternative to the standalone binary). |
| `internal/pg_documentdb_distributed/` | C | Internal only. Multi-node support via Citus. Not shipped in OSS packages or documentdb-local. Do not reference in user-facing work. |

## Development Environment

**Use the VS Code Dev Container** (`.devcontainer/`). It has all dependencies pre-installed.

```
Cmd/Ctrl+Shift+P -> "Dev Containers: Reopen in Container"
```

Forwarded ports: **9712** (PostgreSQL), **10260** (Gateway).

Without the dev container you need: PostgreSQL + PGXS, libbson, PCRE2, Roaring Bitmaps,
intelmathlib, PostGIS, vector, pg_cron, tsm_system_rows, and a Rust toolchain.

## Build

```bash
make                    # Build all C extensions
make install            # Install all extensions
make DEBUG=yes          # Debug build with symbols
make citus-indent       # Format C code (required before commit)
```

For the Rust gateway:
```bash
cd pg_documentdb_gw
cargo make build        # Build workspace
cargo make lint         # Clippy + format check + cargo deny
```

## Testing

**Every contribution must include appropriate tests.** Choose the right test type:

### SQL Regression Tests (pg_regress)

The primary test suite for extension logic. Uses PostgreSQL's `pg_regress` framework —
you write SQL input files and expected output files.

| Suite | Files | Location | Command |
|-------|-------|----------|---------|
| pg_documentdb | 69 | `pg_documentdb/src/test/regress/sql/` | `make -C pg_documentdb check-regress` |
| pg_documentdb_core | 4 | `pg_documentdb_core/src/test/regress/sql/` | `make -C pg_documentdb_core check` |
| Extended RUM | 16 | `pg_documentdb/src/test/extended_rum_tests/sql/` | `make -C pg_documentdb check-extended-rum` |

```bash
make check                              # Run all SQL regression tests
make -C pg_documentdb check-minimal     # Fast subset for quick iteration
make check-valgrind                     # Full suite with memory checking
```

Schedules: `basic_schedule` (full), `minimal_schedule` (fast). Default test port: **58070**.

### Rust Gateway Tests

Unit and integration tests for the MongoDB wire protocol gateway.

| Suite | Tests | Location | Command |
|-------|-------|----------|---------|
| Integration tests | 83 | `pg_documentdb_gw/documentdb_tests/tests/` | `cargo make test` |
| Unit tests (gateway_core) | 6+ | `pg_documentdb_gw/documentdb_gateway_core/src/` | `cargo test -p documentdb_gateway_core` |

```bash
cd pg_documentdb_gw
cargo make test                         # All Rust tests (runs single-threaded)
cargo test --test command_tests         # Run a specific test file
cargo test -p documentdb_gateway_core --lib  # Unit tests only (excludes doc tests)
cargo test -p documentdb_gateway_core   # Unit + doc tests
```

### Gateway Integration Tests

The gateway has its own integration tests in `pg_documentdb_gw/documentdb_tests/` that
validate the gateway operates correctly — protocol handling, authentication, connection
management, command routing, and response formatting. These run against a live PostgreSQL
instance and do not require an external MongoDB client.

```bash
cd pg_documentdb_gw
cargo make test                         # Runs all gateway integration tests
```

### Functional / End-to-End Tests

For **new features**, add functional tests to the separate
[documentdb/functional-tests](https://github.com/documentdb/functional-tests) repository.
These tests validate end-to-end behavior against a running DocumentDB instance using
a MongoDB client and are the right place for higher-level feature validation that goes
beyond SQL regression tests and gateway integration tests.

### Which tests to write

| Change type | Required tests |
|-------------|---------------|
| New SQL feature / operator / command | SQL regression test in `pg_documentdb/src/test/regress/sql/` |
| Core BSON type change | SQL regression test in `pg_documentdb_core/src/test/regress/sql/` |
| RUM index change | Extended RUM test in `pg_documentdb/src/test/extended_rum_tests/sql/` |
| Gateway protocol / auth / connection change | Gateway integration test in `pg_documentdb_gw/documentdb_tests/tests/` |
| New user-facing feature | Functional test in [documentdb/functional-tests](https://github.com/documentdb/functional-tests) |

## Code Style

C code (extensions):
- **PascalCase** for functions: `ExportedPublicFunction()`, `InternalHelper()`
- **UPPERCASE** for macros: `BSON_MAX_ALLOWED_SIZE`
- **`_PG_init()`** / **`_PG_fini()`** for extension entry points
- Standard: `-std=gnu99`, flags: `-Wall -Wextra -Werror -fvisibility=hidden`
- Error handling: PostgreSQL `ereport()` / `errmsg()` / `errdetail_log()`
- File headers: copyright block + brief description

Rust code (gateway):
- Follow the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/naming.html#naming) for naming conventions
- Follow the [Rust API Guidelines Checklist](https://rust-lang.github.io/api-guidelines/checklist.html) and [Microsoft Rust Guidelines Checklist](https://microsoft.github.io/rust-guidelines/guidelines/checklist/index.html) for public APIs
- Formatted on save via rust-analyzer
- Imports use `crate::` prefix

## Contributing

1. Use the Dev Container for development
2. Sign all commits with DCO (`git commit -s`)
3. Include test coverage for changes
4. See [CONTRIBUTING.md](./CONTRIBUTING.md) for full guidelines including AI policy
