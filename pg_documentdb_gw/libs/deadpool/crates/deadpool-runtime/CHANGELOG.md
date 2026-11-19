# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).# Changelog

<!-- next-header -->

## [Unreleased]

## [0.3.1] - 2026-02-03

- Fix typos in the README

This release contains no functional or API changes.

## [0.3.0] - 2026-02-03

- Remove all methods from `Runtime` enum and make them regular functions
  taking the `Runtime` as first argument. This makes it possible to
  re-export the `Runtime` type without needing to re-export the
  `SpawnBlockingError` type as well.
- Mark `Runtime` enum as `non_exhaustive` so future additions of runtimes
  can be non breaking releases.

## [0.2.0] - 2026-02-02

- Bump up MSRV to `1.85` and Rust edition to `2024`
- Add support for `smol` version 2.0
- Mark `rt_async-std_1` feature as deprecated
- Add `SpawnBlockingError::Cancelled` variant

## [0.1.4] - 2024-05-24

- Add `LICENSE-APACHE` and `LICENSE-MIT` files to published crates

## [0.1.3] - 2023-09-26

- Bump up MSRV to `1.63` to match the one of `tokio`

## [0.1.2] - 2021-10-26

- Fix links to tokio and async-std in documentation

## [0.1.1] - 2021-10-26

- Fix tokio feature dependencies

## [0.1.0] - 2021-10-26 (yanked)

- First release

<!-- next-url -->
[Unreleased]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.3.0...HEAD
[0.3.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.2.0...deadpool-runtime-v0.3.0
[0.2.0]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.1.4...deadpool-runtime-v0.2.0
[0.1.4]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.1.3...deadpool-runtime-v0.1.4
[0.1.3]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.1.2...deadpool-runtime-v0.1.3
[0.1.2]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.1.1...deadpool-runtime-v0.1.2
[0.1.1]: https://github.com/deadpool-rs/deadpool/compare/deadpool-runtime-v0.1.0...deadpool-runtime-v0.1.1
[0.1.0]: https://github.com/deadpool-rs/deadpool/releases/tag/deadpool-runtime-v0.1.0
