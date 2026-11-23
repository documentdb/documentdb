# DocumentDB Deadpool Fork

This directory contains local copies of selected crates from the
[`deadpool-rs/deadpool`](https://github.com/deadpool-rs/deadpool) repository.

The crate source and package manifests were copied without changes. This is
vendoring for local gateway dependency resolution, not a narrowed API or a set
of locally modified pool implementations. Machine-readable provenance lives in
[FORK_METADATA.toml](FORK_METADATA.toml).

## Source Baseline

All three crates were copied from upstream commit
[`f4efd12e65b2cc9347f6ca0ee42800cd376ea658`](https://github.com/deadpool-rs/deadpool/commit/f4efd12e65b2cc9347f6ca0ee42800cd376ea658),
also recorded in each crate's `UPSTREAM_COMMIT` file.

| Retained crate | Package version | Upstream release tag | Release-tag commit |
| --- | --- | --- | --- |
| [deadpool](crates/deadpool) | 0.13.1 | [`deadpool-v0.13.1`](https://github.com/deadpool-rs/deadpool/tree/deadpool-v0.13.1) | `bba260f93ef4f7a63c82799563f92518b9e5d42a` |
| [deadpool-runtime](crates/deadpool-runtime) | 0.3.1 | [`deadpool-runtime-v0.3.1`](https://github.com/deadpool-rs/deadpool/tree/deadpool-runtime-v0.3.1) | `362391f640a0a041ec246370c67a99e7b34c9312` |
| [deadpool-postgres](crates/deadpool-postgres) | 0.14.2 | [`deadpool-postgres-v0.14.2`](https://github.com/deadpool-rs/deadpool/tree/deadpool-postgres-v0.14.2) | `bba260f93ef4f7a63c82799563f92518b9e5d42a` |

The package versions and release tags are distinct from the copied source
snapshot. The pinned source includes upstream commits after those release tags;
these are not local backports or crate modifications.

## Retained Scope

The three selected crates retain their upstream source, manifests, tests,
benchmarks, dependencies, and feature declarations where present. Gateway
feature selection does not remove other upstream features from these copies.
The manifests remain authoritative:

- [deadpool/Cargo.toml](crates/deadpool/Cargo.toml)
- [deadpool-runtime/Cargo.toml](crates/deadpool-runtime/Cargo.toml)
- [deadpool-postgres/Cargo.toml](crates/deadpool-postgres/Cargo.toml)

This directory does not vendor the entire upstream repository or its other
adapter crates. Package documentation and license files accompany the selected
crates.

## Publication and Naming Guardrails

The crates retain upstream package names for local dependency compatibility.
Do not publish these vendored copies under the upstream package names. This is
a repository policy, not a claim that the unchanged upstream manifests set
`publish = false`.

Preserve upstream authorship, attribution, and the dual MIT/Apache-2.0 license.
The fork epoch is `documentdb-deadpool-fork-1`.

## Divergence Ledger

There are no local crate source or manifest changes and no selectively applied
patches. Repository integration is limited to local dependency wiring and
provenance records.

| Scope | Local integration |
| --- | --- |
| Gateway dependency declarations and lockfiles | Resolve dependencies to the copied crates. |
| [FORK.md](FORK.md), [FORK_METADATA.toml](FORK_METADATA.toml), and per-crate `UPSTREAM_COMMIT` files | Record provenance and maintenance policy. |

Future source updates must record the selected upstream commit and package
versions. If a future change introduces local crate patches, document them here
and in [FORK_METADATA.toml](FORK_METADATA.toml), classifying them as
`upstream-first`, `upstream-candidate`, or `local-only`.

## Security and Advisory Monitoring

The fork owner must monitor upstream releases and advisories for the retained
crate identities:

- `deadpool`;
- `deadpool-runtime`;
- `deadpool-postgres`.

At minimum, evaluate upstream releases/advisories before release branches and
for any high-severity advisory affecting retained code. Shared vulnerabilities
should be coordinated with the upstream project through the normal responsible
disclosure path. Local-only vulnerabilities should follow this repository's
security process and should not be disclosed through public issues before the
appropriate embargo/coordination decision.

## Validation Commands

For changes to crate source, manifests, or dependency wiring, run these from the
repository root:

```bash
cargo make --cwd pg_documentdb_gw build
cargo make --cwd pg_documentdb_gw test
cargo make --cwd pg_documentdb_gw lint
cargo make --cwd pg_documentdb_gw_host dev
```

Integration tests require a matching PostgreSQL test environment. Provenance-only
documentation changes require metadata and link checks, not product rebuilds.
