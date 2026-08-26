/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/collections/cache/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod async_cache_trait;
mod cache_trait;
mod config;
mod error;
mod ttl_cache;

pub use async_cache_trait::AsyncCache;
pub use cache_trait::Cache;
pub use config::CacheConfiguration;
pub use error::CacheError;
pub use ttl_cache::TtlCache;
