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

use crate::collections::cache::CacheError;

#[cfg_attr(
    not(test),
    expect(dead_code, reason = "This trait may not be used in all configurations")
)]
pub trait Cache<K, V>
where
    K: Debug + Eq + Hash + 'static,
    V: Debug + 'static,
{
    /// # Errors
    ///
    /// Returns [`CacheError::DuplicateKey`] when the key already exists, or
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    fn insert(&self, key: K, value: V) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// Returns [`CacheError::DuplicateKey`] when the key already exists, or
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    fn insert_with_ttl(&self, key: K, value: V, ttl: Duration) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    fn upsert(&self, key: K, value: V) -> Result<(), CacheError>;

    /// # Errors
    ///
    /// [`CacheError::CapacityExceeded`] when the cache is at capacity.
    fn upsert_with_ttl(&self, key: K, value: V, ttl: Duration) -> Result<(), CacheError>;

    fn get(&self, key: &K) -> Option<Arc<V>>;

    fn apply<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> R;

    fn remove(&self, key: &K) -> Option<Arc<V>>;

    #[cfg_attr(test, expect(dead_code, reason = "Not exercised by current tests"))]
    fn refresh(&self, key: &K) -> bool;

    fn update_and_refresh<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> (V, R);

    fn evict_expired(&self) -> Vec<Arc<V>>;

    #[cfg_attr(test, expect(dead_code, reason = "Not exercised by current tests"))]
    fn contains_key(&self, key: &K) -> bool;

    fn len(&self) -> usize;

    #[cfg_attr(test, expect(dead_code, reason = "Not exercised by current tests"))]
    fn clear(&self);

    #[cfg_attr(test, expect(dead_code, reason = "Not exercised by current tests"))]
    fn is_empty(&self) -> bool;
}
