# DocumentDB tokio-postgres Fork

This directory contains the DocumentDB gateway's local copy of `tokio-postgres`
0.7.18, derived from
[`tsharp/rust-postgres`](https://github.com/tsharp/rust-postgres), branch
[`fix/memory-retention`](https://github.com/tsharp/rust-postgres/tree/fix/memory-retention).
The original upstream project is
[`rust-postgres/rust-postgres`](https://github.com/rust-postgres/rust-postgres).

This is an explicitly selected source snapshot with additional local changes,
not a tracking checkout of either repository. Machine-readable provenance lives
in [FORK_METADATA.toml](FORK_METADATA.toml).

## Source Baseline

| Reference | Pinned identity |
| --- | --- |
| Upstream crate version | `tokio-postgres` 0.7.18 |
| Upstream release tag | [`tokio-postgres-v0.7.18`](https://github.com/rust-postgres/rust-postgres/tree/tokio-postgres-v0.7.18) |
| Release-tag commit | [`f1cb6ec0d5766b136cbd68f3010d64142a5daa66`](https://github.com/rust-postgres/rust-postgres/commit/f1cb6ec0d5766b136cbd68f3010d64142a5daa66) |
| Upstream fork point | [`1084ca8f5b5302e161892f2fa40abf71b4060c10`](https://github.com/rust-postgres/rust-postgres/commit/1084ca8f5b5302e161892f2fa40abf71b4060c10) |
| Source fork commit | [`9ee7449aa9a52e3ce412ddd3d35279f97a628054`](https://github.com/tsharp/rust-postgres/commit/9ee7449aa9a52e3ce412ddd3d35279f97a628054) |
| Retained package | [crates/tokio-postgres](crates/tokio-postgres) |

The upstream fork point follows the 0.7.18 release tag while retaining that crate
version. The release tag, fork point, and patched fork commit are therefore
recorded separately. The package version does not imply that this source is
identical to the crates.io release.

The branch name identifies where the fork changes were developed; the commit
identifies the pinned source used for provenance. Moving the branch does not
automatically update this local copy.

## Fork Changes

The source branch adds configurable connection buffer sizing and fixes retained
buffer allocations that could otherwise keep memory sized for an earlier large
request or response.

The four fork commits after the upstream fork point are:

| Commit | Change |
| --- | --- |
| [`01a5642`](https://github.com/tsharp/rust-postgres/commit/01a5642bdc66ab414687d57d97bf8bafcdfa3705) | Initial buffer memory-retention fix |
| [`0b36f94`](https://github.com/tsharp/rust-postgres/commit/0b36f945a3092bf1e2fe79332313ab2988ce11fe) | Regression tests |
| [`7956f02`](https://github.com/tsharp/rust-postgres/commit/7956f0217c9cfb41f1f86c511ab8d190e049bbe0) | Correct where retained memory is released |
| [`9ee7449`](https://github.com/tsharp/rust-postgres/commit/9ee7449aa9a52e3ce412ddd3d35279f97a628054) | Lint fixes |

The retained API includes
[`Config::buffer_size` and `Config::get_buffer_size`](crates/tokio-postgres/src/config.rs).
Buffer sizing is part of this crate's API and does not require a custom cfg.
The [codec](crates/tokio-postgres/src/codec.rs) bounds oversized decode-buffer
retention when the remaining data fits the configured capacity.

## Retained Scope

Only the `tokio-postgres` package is retained from the source repository, under
[crates/tokio-postgres](crates/tokio-postgres), together with license and fork
documentation. The package includes source, tests, benchmarks, its changelog,
and local integration files.

Other packages from the upstream workspace, including `postgres`,
`postgres-protocol`, `postgres-types`, and `postgres-derive`, are not vendored in
this directory. Dependencies and supported features are defined by the retained
[Cargo.toml](crates/tokio-postgres/Cargo.toml). Gateway consumers use `runtime`,
`with-serde_json-1`, and `array-impls`.

The original authors, upstream repository identity, and dual MIT/Apache-2.0
license remain the basis of this fork. Preserve third-party notices and license
terms when updating retained files.

## Divergence Ledger

The local package is not a byte-for-byte copy of the pinned fork commit.

| Change class | Files / scope | Rationale | Upstreamability |
| --- | --- | --- | --- |
| Fork buffer-retention fixes | Four fork commits listed above | Configure buffer capacity and release oversized retained allocations. | upstream-candidate |
| Additional buffer reclamation | [client.rs](crates/tokio-postgres/src/client.rs), [connection.rs](crates/tokio-postgres/src/connection.rs) | Reclaim oversized request buffers and empty read/write buffers on fully idle connections. | upstream-candidate |
| Package integration | [Cargo.toml](crates/tokio-postgres/Cargo.toml), gateway dependency declarations, and lockfiles | Retain a local, non-publishable package with dependencies resolved outside the original workspace. | local-only |
| Documentation and test adaptation | Package documentation, tests, benchmarks, formatting configuration, and fork metadata | Maintain the retained package in its local layout and dependency environment. | local-only |

Update this ledger and [FORK_METADATA.toml](FORK_METADATA.toml) when changing
the source baseline, retained behavior, dependencies, or supported features.
Generic fixes should be considered for upstream contribution. Do not describe a
fork patch as an upstream backport unless its upstream origin is verified.

## Publication and Maintenance

The retained crate keeps its upstream package name for local dependency
compatibility. Its manifest sets `publish = false`; it must not be published
under the upstream package name.

Monitor upstream releases and advisories for `tokio-postgres`. A source update
must deliberately select and record a new upstream baseline and fork commit,
then account for local changes rather than overwriting them with a branch tip.
The fork epoch is `documentdb-tokio-postgres-fork-1`.

## Validation

For changes to retained source or manifests, run the existing gateway build,
lint, test, and host validation tasks from the repository root:

```bash
cargo make --cwd pg_documentdb_gw build
cargo make --cwd pg_documentdb_gw lint
cargo make --cwd pg_documentdb_gw test
cargo make --cwd pg_documentdb_gw_host dev
```

Integration tests require a matching PostgreSQL test environment. Consumers
must also validate their builds against this local package: switching to the
unmodified registry release is not equivalent to retaining the fork's buffer
sizing API and memory-retention behavior.
