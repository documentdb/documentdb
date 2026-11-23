# Deadpool runtime abstraction [![Latest Version](https://img.shields.io/crates/v/deadpool-runtime.svg)](https://crates.io/crates/deadpool-runtime) [![Build Status](https://img.shields.io/github/actions/workflow/status/deadpool-rs/deadpool/deadpool-runtime.yml?branch=main)](https://github.com/deadpool-rs/deadpool/actions/workflows/deadpool-runtime.yml?query=branch%3Amain) ![Unsafe forbidden](https://img.shields.io/badge/unsafe-forbidden-success.svg "Unsafe forbidden") [![Rust 1.85+](https://img.shields.io/badge/rustc-1.85+-lightgray.svg "Rust 1.85+")](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)

Deadpool is a dead simple async pool for connections and objects
of any type.

This crate provides a simple `Runtime` enum that can be used to
target multiple runtimes. This crate avoids boxed futures and
and only implements things actually needed by the `deadpool` crates.

**Note:** This crate is intended for making the development of
`deadpool-*` crates easier. Other libraries and binary projects
normally should not use this directly and use some provided
reexports by the crates using it.

## Features

| Feature       | Description                                                              | Extra dependencies                     | Default |
| ------------- | ------------------------------------------------------------------------ | -------------------------------------- | ------- |
| `tokio_1`     | Enable support for [tokio](https://crates.io/crates/tokio) crate         | `tokio/time`, `tokio/rt`               | no      |
| `async-std_1` | Enable support for [async-std](https://crates.io/crates/async-std) crate | `async-std`                            | no      |
| `smol_2`      | Enable support for [smol](https://crates.io/crates/smol) crate           | `async-io`, `blocking`, `futures-lite` | no      |

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0)>
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT)>

at your option.
