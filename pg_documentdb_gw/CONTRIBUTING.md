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
