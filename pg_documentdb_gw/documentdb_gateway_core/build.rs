/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/build.rs
 *
 *-------------------------------------------------------------------------
 */

fn main() {
    // `pg_buffer_size` is a build-time flag set by consumers that supply a
    // `tokio-postgres` build exposing `Config::buffer_size`. It is intentionally
    // a `cfg` rather than a Cargo feature so that `--all-features` builds do not
    // enable code paths requiring the extended API. Declaring it here keeps the
    // `unexpected_cfgs` lint quiet when the flag is not set.
    println!("cargo::rustc-check-cfg=cfg(pg_buffer_size)");
}
