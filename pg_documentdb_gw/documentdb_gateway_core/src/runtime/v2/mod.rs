/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/mod.rs
 *
 *-------------------------------------------------------------------------
 */

//! Implements the gateway runtime.

#[cfg(feature = "runtime-benchmarks")]
#[doc(hidden)]
pub mod benchmarks;
mod body;
mod connection;
mod handler;
mod listener;
mod protocol;
mod wire;

#[cfg(test)]
mod tests;

pub use listener::run_gateway;
