/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/collections/cache/cache_trait.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;
use std::hash::Hash;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;

use crate::collections::cache::CacheError;

#[cfg_attr(
    not(test),
    expect(dead_code, reason = "This trait may not be used in all configurations")
)]
#[async_trait]
pub trait AsyncCache<K, V>
where
    K: Debug + Eq + Hash + 'static,
    V: Debug + 'static,
{
    /// # Errors
    ///
    /// Returns [`CacheError::DuplicateKey`] when the key already exists, or
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    async fn insert_async(&self, key: K, value: V) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// Returns [`CacheError::DuplicateKey`] when the key already exists, or
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    async fn insert_with_ttl_async(
        &self,
        key: K,
        value: V,
        ttl: Duration,
    ) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    async fn upsert_async(&self, key: K, value: V) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    async fn upsert_with_ttl_async(
        &self,
        key: K,
        value: V,
        ttl: Duration,
    ) -> Result<(), CacheError>;

    async fn get_async(&self, key: &K) -> Option<Arc<V>>;

    async fn apply_async<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> R + Send;

    async fn remove_async(&self, key: &K) -> Option<Arc<V>>;

    async fn refresh_async(&self, key: &K) -> bool;

    async fn update_and_refresh_async<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> (V, R) + Send;

    async fn evict_expired_async(&self) -> Vec<Arc<V>>;

    async fn contains_key_async(&self, key: &K) -> bool;

    async fn clear_async(&self);
}
