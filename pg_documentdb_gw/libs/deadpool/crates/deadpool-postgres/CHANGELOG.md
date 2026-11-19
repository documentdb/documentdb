# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- next-header -->

## [Unreleased]

- Allow the `dbname` to be missing from the configuration. `create_pool` now
  leaves it unset so that `tokio-postgres` applies its default of connecting to
  a database named after the user. An empty `dbname` is still rejected.
  **Breaking:** `ConfigError::DbnameMissing` was removed.

## [0.14.2] - 2026-08-26

- Coalesce concurrent statement preparations. Tasks racing to prepare the same
  query now share a single `PREPARE` instead of each sending their own. If that
  preparation fails or is cancelled, one of the waiting tasks starts a fresh one
  instead of failing along with it.
- Bump up MSRV to `1.85` and Rust edition to `2024`
- Re-export `tokio-postgres` features:
  - `with-bit-vec-0_9`
- Update `tokio-postgres` dependency to version `0.7.14`
- Update `deadpool` dependency to version `0.13.1`

## [0.14.1] - 2024-12-18

- Add missing re-export of `LoadBalanceHosts`

## [0.14.0] - 2024-06-04

- Add back `async_trait` to the `GenericClient` trait.
  The removal of `async_trait` caused some errors for code using
  the generic client interface. A test was added to ensure future
  removals of `async_trait` will not cause this code to break.

## [0.13.2] - 2024-05-07

- Add WASM support
- Expose API for providing a custom `Connect` implementation.
- Add `+ Send` to futures returned by `GenericClient`

## [0.13.1] - 2024-05-04

- Update `deadpool` dependency to version `0.12`
- Add `LICENSE-APACHE` and `LICENSE-MIT` files to published crates

## [0.13.0] - 2024-04-01

- Update `deadpool` dependency to version `0.11`
- Remove `async_trait` dependency
- Bump up MSRV to `1.75`

## [0.12.1] - 2023-12-18

- Fix `Config::url` handling

## [0.12.0] - 2023-12-15

- Add `load_balance_hosts` to `Config` struct.
- Add `hostaddr` and `hostaddrs` to `Config` struct.
- Add `url` field to `Config` struct. This enables parsing of
  connection URLs.

## [0.11.0] - 2023-09-26

- **BREAKING:** Disconnect immediately from the database when dropping
  clients. This is considered a breaking change as in previous versions
  the connections would stick around until all queued queries were
  processed. This was considered a potential leak of resources. The
  `Connection` object is now tied to the lifetime of the `ClientWrapper`
  and dropped as soon as possible. The disconnect is not graceful and
  you might see error messages in the database log.
- Update `deadpool` dependency to version `0.10`
- Bump up MSRV to `1.63` to match the one of `tokio`

## [0.10.5] - 2023-01-24

- Fix infinite recursion in `GenericClient`

## [0.10.4] - 2023-01-16 (yanked)

- Add `GenericClient`

## [0.10.3] - 2022-10-26

- Make `Transaction::statement_cache` field public

## [0.10.2] - 2022-03-22

- Export `TargetSessionAttrs` and `ChannelBinding` enums (part of `Config`
  struct)

## [0.10.1] - 2021-11-15

- Config structs now implement `Serialize`

## [0.10.0] - 2021-10-18

- __Breaking:__ Replace `config` feature with `serde` (opted out by default)
- Re-export `deadpool::managed::Timeouts`
- Add `Runtime` parameter to `Config::create_pool` method
- Remove redundant `futures` dependency

## [0.9.0] - 2021-06-01

- Remove generic `<T>` parameter from `Manager`, `Pool` and `Client`
  types. This parameter was added by accident when deadpool switched
  to using associated types.

## [0.8.1] - 2021-06-01

- Update `tokio-postgres` dependency to version `0.7.2`
  This crate depends on the `GenericClient::client` method
  which was added in `tokio-postgres` version `0.7.2`.

## [0.8.0] - 2021-05-21

- Do not detect unix domain socket paths at config creation.
- Update `config` dependency to version `0.11`
- Remove deprecated `from_env` methods
- Add `Manager::statement_caches` field which provides access
  to managing the statement cache for all clients.
- Rename `prepare` to `prepare_cached` and `prepare_typed` to
  `prepare_typed_cached`. This makes the non-caching prepare
  methods available without having to dereference `ClientWrapper`
  or `Transaction` objects first.
- Add `rt_tokio_1` and `rt_async-std_1` features
- Enable `RecyclingMethod::Fast` by default

## [0.7.0] - 2020-12-26

- Update `tokio` dependency to version `1`
- Update `tokio-postgres` dependency to version `0.7`
- Re-export `deadpool::managed::PoolConfig`
- Add `StatementCache::remove` method

## [0.6.0] - 2020-11-04

- Update `tokio` dependency to version `0.3`
- Update `tokio-postgres` dependency to version `0.6`

## [0.5.6] - 2020-07-14

- Add `Config::new` method
- Add `Client::build_transaction` method which makes it possible to
  use the `TransactionBuilder` with the statement cache.
- Add `RecyclingMethod::Clean` which works similar to `DISCARD ALL`
  but makes sure the statement cache is not rendered ineffective.
- Add `RecyclingMethod::Custom` which allows to execute arbitary SQL
  when recycling connections.
- Re-export `tokio_postgres` crate

## [0.5.5] - 2020-02-28

- Deprecate `Config::from_env`
- Add `Manager::from_config`, `ManagerConfig` and `RecyclingMethod` which
  makes it possible to specify how connections are recycled. The current
  default recycling method is `Verified` which is the same as before. The
  upcoming `0.6` release of this crate will change the default to `Fast`.

## [0.5.4] - 2020-01-26

- Implement `DerefMut` for `Transaction` wrapper
- Add `transaction` method to `Transaction` wrapper

## [0.5.3] - 2020-01-24

- Add `#[derive(Clone)]` to `Config` struct
- Make `config` module public

## [0.5.2] - 2020-01-18

- Disable `default-features` for `deadpool` dependency

## [0.5.1] - 2020-01-17

- Fix windows support

## [0.5.0] - 2020-01-16

- Add support for `config` crate

## [0.4.3] - 2020-01-10

- `prepare` and `prepare_typed` now accept a `&self` instead of `&mut self`
  which fixes support for pipelining.

## [0.4.2] - 2019-12-31

- Add `PoolError` type alias

## [0.4.1] - 2019-12-29

- Update to `tokio-postgres 0.5.1`
- Add back `DerefMut` implementation for `deadpool_postgres::Client` which
  makes it compatible with code expecting `&mut tokio_postgres::Client`.
- Add statement cache support for `Client::prepare_typed` and
  `Transaction::prepare_typed`.

## [0.4.0] - 2019-12-19

- Rename `Client` struct to `ClientWrapper`
- Add `Client` type alias

## [0.3.0] - 2019-12-13

- Add `StatementCache` struct with the functions `size` and `clear` which
  are now accessible via `Connection::statement_cache` and
  `Transaction::statement_cache`.
- Make recycling more robust by changing the `Manager::recycle` to a non
  consuming API.

## [0.2.3] - 2019-12-02

- Add documentation for `docs.rs`
- Improve example in `README.md` and crate root
- Fix `Transaction::commit` and `Transaction::rollback`

## [0.2.2] - 2019-12-02

- Update to `tokio 0.2` and `tokio-postgres 0.5.0-alpha.2`

## [0.2.1] - 2019-11-18

- `deadpool_postgres::Client` no longer implements `DerefMut` which was not
    needed anyways.
- `deadpool_postgres::Client.transaction` now returns a wrapped transaction
    object which utilizes the statement cache of the wrapped client.

## [0.2.0] - 2019-11-18

- First release

<!-- next-url -->
[Unreleased]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.14.2...HEAD
[0.14.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.14.1...deadpool-postgres-v0.14.2
[0.14.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.14.0...deadpool-postgres-v0.14.1
[0.14.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.13.2...deadpool-postgres-v0.14.0
[0.13.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.13.1...deadpool-postgres-v0.13.2
[0.13.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.13.0...deadpool-postgres-v0.13.1
[0.13.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.12.1...deadpool-postgres-v0.13.0
[0.12.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.12.0...deadpool-postgres-v0.12.1
[0.12.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.11.0...deadpool-postgres-v0.12.0
[0.11.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.5...deadpool-postgres-v0.11.0
[0.10.5]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.4...deadpool-postgres-v0.10.5
[0.10.4]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.3...deadpool-postgres-v0.10.4
[0.10.3]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.2...deadpool-postgres-v0.10.3
[0.10.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.1...deadpool-postgres-v0.10.2
[0.10.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.10.0...deadpool-postgres-v0.10.1
[0.10.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.9.0...deadpool-postgres-v0.10.0
[0.9.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.8.1...deadpool-postgres-v0.9.0
[0.8.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.8.0...deadpool-postgres-v0.8.1
[0.8.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.7.0...deadpool-postgres-v0.8.0
[0.7.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.6.0...deadpool-postgres-v0.7.0
[0.6.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.6...deadpool-postgres-v0.6.0
[0.5.6]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.5...deadpool-postgres-v0.5.6
[0.5.5]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.4...deadpool-postgres-v0.5.5
[0.5.4]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.3...deadpool-postgres-v0.5.4
[0.5.3]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.2...deadpool-postgres-v0.5.3
[0.5.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.1...deadpool-postgres-v0.5.2
[0.5.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.5.0...deadpool-postgres-v0.5.1
[0.5.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.4.3...deadpool-postgres-v0.5.0
[0.4.3]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.4.2...deadpool-postgres-v0.4.3
[0.4.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.4.1...deadpool-postgres-v0.4.2
[0.4.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.4.0...deadpool-postgres-v0.4.1
[0.4.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.3.0...deadpool-postgres-v0.4.0
[0.3.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.2.3...deadpool-postgres-v0.3.0
[0.2.3]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.2.2...deadpool-postgres-v0.2.3
[0.2.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.2.1...deadpool-postgres-v0.2.2
[0.2.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-postgres-v0.2.0...deadpool-postgres-v0.2.1
[0.2.0]: https://github.com/deadpool-rs/deadpool/releases/tag/deadpool-postgres-v0.2.0
