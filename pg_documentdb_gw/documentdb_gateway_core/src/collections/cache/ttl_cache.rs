/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/collections/cache/ttl_cache.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::{hash::Hash, time::Duration};

use async_trait::async_trait;
use scc::HashMap;
use tokio::sync::{Mutex, MutexGuard};

use crate::collections::cache::config::CapacityEnforcement;
use crate::collections::cache::{AsyncCache, Cache, CacheConfiguration, CacheError};
use crate::time::EpochClock;

#[cfg(test)]
static DELAY_BOUNDED_INSERTS_FOR_TESTS: AtomicBool = AtomicBool::new(false);

#[cfg(test)]
fn maybe_delay_bounded_insert_for_tests() {
    if DELAY_BOUNDED_INSERTS_FOR_TESTS.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// A cache entry that stores a value along with its time-to-live (TTL) and expiration time.
#[derive(Debug)]
pub struct TtlCacheEntry<V> {
    /// The value stored in the cache entry.
    value: Arc<V>,

    /// When creating the cache entry, this is the time-to-live (TTL) duration.
    ttl: Duration,

    /// The expiration time of the cache entry, represented as a timestamp.
    expires_at: u64,
}

impl<V> TtlCacheEntry<V> {
    /// Creates a new cache entry with the given value and TTL.
    pub fn new(value: V, ttl: Duration) -> Self {
        let expires_at = if ttl.is_zero() {
            0
        } else {
            EpochClock::almost_now_timestamp() + ttl.as_secs()
        };

        Self {
            value: Arc::new(value),
            ttl,
            expires_at,
        }
    }

    /// Returns `true` if the cache entry has expired, `false` otherwise.
    pub fn is_expired(&self) -> bool {
        if self.expires_at == 0 {
            false
        } else {
            EpochClock::almost_now_timestamp() >= self.expires_at
        }
    }

    /// Returns a clone of the value stored in the cache entry.
    pub fn value(&self) -> Arc<V> {
        Arc::clone(&self.value)
    }

    /// Returns a reference to the value stored in the cache entry.
    pub fn value_ref(&self) -> &V {
        self.value.as_ref()
    }

    /// Replaces the value stored in the cache entry with a new value.
    pub fn replace_value(&mut self, value: V) {
        self.value = Arc::new(value);
    }

    /// Refreshes the cache entry by extending its expiration time based on its TTL.
    pub fn refresh(&mut self) {
        if !self.ttl.is_zero() {
            self.expires_at = EpochClock::almost_now_timestamp() + self.ttl.as_secs();
        }
    }

    #[cfg(test)]
    /// Expires the cache entry immediately.
    pub const fn expire(&mut self) {
        self.expires_at = 1;
    }
}

#[derive(Debug)]
pub struct TtlCache<K, V>
where
    K: Debug + Eq + Hash + 'static,
    V: Debug + 'static,
{
    /// The items stored in the cache, mapped by their keys.
    items: HashMap<K, TtlCacheEntry<V>>,

    /// Serializes size-changing operations when capacity bounds are enforced.
    size_change_lock: Mutex<()>,

    /// The configuration for the cache, including default TTL and maximum capacity.
    config: CacheConfiguration,
}

impl<K, V> TtlCache<K, V>
where
    K: Debug + Eq + Hash + 'static,
    V: Debug + 'static,
{
    #[must_use]
    pub fn new(config: CacheConfiguration) -> Self {
        Self {
            items: HashMap::with_capacity(config.initial_capacity()),
            size_change_lock: Mutex::new(()),
            config,
        }
    }

    #[must_use]
    fn size_change_guard(&self) -> Option<MutexGuard<'_, ()>> {
        if self.config.max_capacity() == 0
            || self.config.max_capacity_enforcement() == CapacityEnforcement::Relaxed
        {
            None
        } else {
            Some(self.size_change_lock.blocking_lock())
        }
    }

    #[must_use]
    async fn size_change_guard_async(&self) -> Option<MutexGuard<'_, ()>>
    where
        K: Send + Sync,
        V: Send + Sync,
    {
        if self.config.max_capacity() == 0
            || self.config.max_capacity_enforcement() == CapacityEnforcement::Relaxed
        {
            None
        } else {
            Some(self.size_change_lock.lock().await)
        }
    }
}

impl<K, V> Cache<K, V> for TtlCache<K, V>
where
    K: Debug + Eq + Hash + 'static,
    V: Debug + 'static,
{
    fn insert(&self, key: K, value: V) -> Result<(), CacheError> {
        self.insert_with_ttl(key, value, self.config.default_ttl())
    }

    fn insert_with_ttl(&self, key: K, value: V, ttl: Duration) -> Result<(), CacheError> {
        let _size_change_guard = self.size_change_guard();

        if self.config.max_capacity() > 0 && self.items.len() >= self.config.max_capacity() {
            return Err(CacheError::CapacityExceeded);
        }

        #[cfg(test)]
        maybe_delay_bounded_insert_for_tests();

        self.items
            .insert_sync(key, TtlCacheEntry::new(value, ttl))
            .map_err(|_insert_error| CacheError::DuplicateKey)
    }

    fn upsert(&self, key: K, value: V) -> Result<(), CacheError> {
        self.upsert_with_ttl(key, value, self.config.default_ttl())
    }

    fn upsert_with_ttl(&self, key: K, value: V, ttl: Duration) -> Result<(), CacheError> {
        let _size_change_guard = self.size_change_guard();

        if self.config.max_capacity() > 0
            && !self.items.contains_sync(&key)
            && self.items.len() >= self.config.max_capacity()
        {
            return Err(CacheError::CapacityExceeded);
        }

        #[cfg(test)]
        maybe_delay_bounded_insert_for_tests();

        self.items.upsert_sync(key, TtlCacheEntry::new(value, ttl));

        Ok(())
    }

    fn get(&self, key: &K) -> Option<Arc<V>> {
        self.items
            .read_sync(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    Some(entry.value())
                }
            })
            .flatten()
    }

    fn apply<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> R,
    {
        let mut apply = Some(f);

        self.items
            .read_sync(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    let apply = apply.take()?;
                    Some(apply(entry.value_ref()))
                }
            })
            .flatten()
    }

    fn remove(&self, key: &K) -> Option<Arc<V>> {
        let _size_change_guard = self.size_change_guard();

        self.items.remove_sync(key).map(|(_, entry)| entry.value())
    }

    fn refresh(&self, key: &K) -> bool {
        self.items
            .update_sync(key, |_, entry| {
                entry.refresh();
            })
            .is_some()
    }

    fn update_and_refresh<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> (V, R),
    {
        let mut update = Some(f);

        self.items
            .update_sync(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    let update = update.take()?;
                    let (value, result) = update(entry.value_ref());
                    entry.replace_value(value);
                    entry.refresh();
                    Some(result)
                }
            })
            .flatten()
    }

    fn evict_expired(&self) -> Vec<Arc<V>> {
        let _size_change_guard = self.size_change_guard();
        let mut removed = Vec::new();
        self.items.retain_sync(|_, entry| {
            if entry.is_expired() {
                removed.push(entry.value());
                false
            } else {
                true
            }
        });
        removed
    }

    fn contains_key(&self, key: &K) -> bool {
        self.items.contains_sync(key)
    }

    fn len(&self) -> usize {
        self.items.len()
    }

    fn clear(&self) {
        let _size_change_guard = self.size_change_guard();

        self.items.clear_sync();
    }

    fn is_empty(&self) -> bool {
        self.items.len() == 0
    }
}

#[async_trait]
impl<K, V> AsyncCache<K, V> for TtlCache<K, V>
where
    K: Debug + Eq + Hash + Send + Sync + 'static,
    V: Debug + Send + Sync + 'static,
{
    async fn insert_async(&self, key: K, value: V) -> Result<(), CacheError> {
        self.insert_with_ttl_async(key, value, self.config.default_ttl())
            .await
    }

    async fn insert_with_ttl_async(
        &self,
        key: K,
        value: V,
        ttl: Duration,
    ) -> Result<(), CacheError> {
        let _size_change_guard = self.size_change_guard_async().await;

        if self.config.max_capacity() > 0 && self.items.len() >= self.config.max_capacity() {
            return Err(CacheError::CapacityExceeded);
        }

        #[cfg(test)]
        maybe_delay_bounded_insert_for_tests();

        self.items
            .insert_async(key, TtlCacheEntry::new(value, ttl))
            .await
            .map_err(|_insert_error| CacheError::DuplicateKey)
    }

    async fn upsert_async(&self, key: K, value: V) -> Result<(), CacheError> {
        self.upsert_with_ttl_async(key, value, self.config.default_ttl())
            .await
    }

    async fn upsert_with_ttl_async(
        &self,
        key: K,
        value: V,
        ttl: Duration,
    ) -> Result<(), CacheError> {
        let _size_change_guard = self.size_change_guard_async().await;

        if self.config.max_capacity() > 0
            && !self.items.contains_async(&key).await
            && self.items.len() >= self.config.max_capacity()
        {
            return Err(CacheError::CapacityExceeded);
        }

        #[cfg(test)]
        maybe_delay_bounded_insert_for_tests();

        self.items
            .upsert_async(key, TtlCacheEntry::new(value, ttl))
            .await;

        Ok(())
    }

    async fn get_async(&self, key: &K) -> Option<Arc<V>> {
        self.items
            .read_async(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    Some(entry.value())
                }
            })
            .await
            .flatten()
    }

    async fn apply_async<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> R + Send,
    {
        self.items
            .read_async(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    Some(f(entry.value_ref()))
                }
            })
            .await
            .flatten()
    }

    async fn remove_async(&self, key: &K) -> Option<Arc<V>> {
        let _size_change_guard = self.size_change_guard_async().await;

        self.items
            .remove_async(key)
            .await
            .map(|(_, entry)| entry.value())
    }

    async fn refresh_async(&self, key: &K) -> bool {
        self.items
            .update_async(key, |_, entry| {
                entry.refresh();
            })
            .await
            .is_some()
    }

    async fn update_and_refresh_async<F, R>(&self, key: &K, f: F) -> Option<R>
    where
        F: FnOnce(&V) -> (V, R) + Send,
    {
        let mut update = Some(f);

        self.items
            .update_async(key, |_, entry| {
                if entry.is_expired() {
                    None
                } else {
                    let update = update.take()?;
                    let (value, result) = update(entry.value_ref());
                    entry.replace_value(value);
                    entry.refresh();
                    Some(result)
                }
            })
            .await
            .flatten()
    }

    async fn evict_expired_async(&self) -> Vec<Arc<V>> {
        let _size_change_guard = self.size_change_guard_async().await;
        let mut removed = Vec::new();
        self.items
            .retain_async(|_, entry| {
                if entry.is_expired() {
                    removed.push(entry.value());
                    false
                } else {
                    true
                }
            })
            .await;

        removed
    }

    async fn contains_key_async(&self, key: &K) -> bool {
        self.items.contains_async(key).await
    }

    async fn clear_async(&self) {
        self.items.clear_async().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct InsertDelayGuard;

    impl InsertDelayGuard {
        fn enable() -> Self {
            DELAY_BOUNDED_INSERTS_FOR_TESTS.store(true, Ordering::Relaxed);
            Self
        }
    }

    impl Drop for InsertDelayGuard {
        fn drop(&mut self) {
            DELAY_BOUNDED_INSERTS_FOR_TESTS.store(false, Ordering::Relaxed);
        }
    }

    fn test_cache() -> TtlCache<u32, String> {
        TtlCache::new(CacheConfiguration::new(
            Duration::from_mins(1),
            None,
            None,
            None,
        ))
    }

    #[test]
    fn test_scc_initial_capacity() {
        let map = scc::HashMap::with_capacity(1024);

        for i in 1..=128 {
            map.insert_sync(i, format!("yo {i}!")).unwrap();
        }

        assert_eq!(map.capacity(), 1024);
    }

    #[test]
    fn test_scc_not_max_capacity() {
        let map = scc::HashMap::with_capacity(64);

        for i in 1..=128 {
            map.insert_sync(i, format!("yo {i}!")).unwrap();
        }

        assert!(map.capacity() > 64);
    }

    #[test]
    fn apply_returns_mapped_value() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let value_len = cache.apply(&1, String::len);

        assert_eq!(value_len, Some(5));
    }

    #[test]
    fn update_and_refresh_replaces_cached_value() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let old_len = cache.update_and_refresh(&1, |value| (format!("{value}!"), value.len()));

        assert_eq!(old_len, Some(5));
        assert_eq!(cache.get(&1).unwrap().as_str(), "value!");
    }

    #[test]
    fn remove_returns_arc_value_when_unreferenced() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let removed = cache.remove(&1).unwrap();

        assert_eq!(removed.as_str(), "value");
        assert!(cache.get(&1).is_none());
    }

    #[test]
    fn remove_returns_shared_arc_when_arc_is_shared() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let shared = cache.get(&1).unwrap();
        let removed = cache.remove(&1).unwrap();

        assert!(Arc::ptr_eq(&shared, &removed));
        assert_eq!(shared.as_str(), "value");
        assert!(cache.get(&1).is_none());
    }

    #[test]
    #[expect(
        clippy::needless_collect,
        reason = "We need to collect the handles to join them later - this causes a deadlock if we don't"
    )]
    fn insert_with_ttl_enforces_capacity_under_parallel_inserts() {
        let _insert_delay_guard = InsertDelayGuard::enable();
        let cache = Arc::new(TtlCache::new(CacheConfiguration::new(
            Duration::from_mins(1),
            Some(1),
            Some(1),
            Some(CapacityEnforcement::Strict),
        )));
        let start = Arc::new(std::sync::Barrier::new(8));

        let handles: Vec<_> = (0..8)
            .map(|key| {
                let cache = Arc::clone(&cache);
                let start = Arc::clone(&start);
                std::thread::spawn(move || {
                    start.wait();
                    cache.insert(key, format!("value{key}"))
                })
            })
            .collect();

        let results: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(CacheError::CapacityExceeded)))
                .count(),
            7
        );
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn evict_expired_removes_expired_entries() {
        let cache = test_cache();
        cache.insert(1, "value1".to_owned()).unwrap();
        cache.insert(2, "value2".to_owned()).unwrap();

        // Manually expire the first entry
        cache.items.update_sync(&1, |_, entry| {
            entry.expire();
        });

        let removed = cache.evict_expired();

        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].as_str(), "value1");
        assert!(cache.get(&1).is_none());
        assert!(cache.get(&2).is_some());
    }

    #[test]
    fn duplicate_key_insertion_returns_error() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let result = cache.insert(1, "new_value".to_owned());

        assert!(matches!(result, Err(CacheError::DuplicateKey)));
        assert_eq!(cache.get(&1).unwrap().as_str(), "value");
    }

    #[test]
    fn upsert_with_ttl_allows_duplicate_keys() {
        let cache = test_cache();
        cache.insert(1, "value".to_owned()).unwrap();

        let result = cache.upsert(1, "new_value".to_owned());

        let _ = result.is_ok();
        assert_eq!(cache.get(&1).unwrap().as_str(), "new_value");
    }

    #[tokio::test]
    async fn apply_async_returns_mapped_value() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        let value_len = cache.apply_async(&1, String::len).await;

        assert_eq!(value_len, Some(5));
    }

    #[tokio::test]
    async fn apply_async_returns_none_for_missing_key() {
        let cache = test_cache();

        let value_len = cache.apply_async(&1, String::len).await;

        assert_eq!(value_len, None);
    }

    #[tokio::test]
    async fn update_and_refresh_async_replaces_cached_value() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        let old_len = cache
            .update_and_refresh_async(&1, |value| (format!("{value}!"), value.len()))
            .await;

        assert_eq!(old_len, Some(5));
        assert_eq!(cache.get_async(&1).await.unwrap().as_str(), "value!");
    }

    #[tokio::test]
    async fn update_and_refresh_async_returns_none_for_missing_key() {
        let cache = test_cache();

        let result = cache
            .update_and_refresh_async(&1, |value: &String| (value.clone(), value.len()))
            .await;

        assert_eq!(result, None);
    }

    #[tokio::test]
    async fn remove_async_returns_arc_value_when_unreferenced() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        let removed = cache.remove_async(&1).await.unwrap();

        assert_eq!(removed.as_str(), "value");
        assert!(cache.get_async(&1).await.is_none());
    }

    #[tokio::test]
    async fn remove_async_returns_shared_arc_when_arc_is_shared() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        let shared = cache.get_async(&1).await.unwrap();
        let removed = cache.remove_async(&1).await.unwrap();

        assert!(Arc::ptr_eq(&shared, &removed));
        assert_eq!(shared.as_str(), "value");
        assert!(cache.get_async(&1).await.is_none());
    }

    #[tokio::test]
    async fn remove_async_returns_none_for_missing_key() {
        let cache = test_cache();

        assert!(cache.remove_async(&1).await.is_none());
    }

    #[tokio::test]
    async fn refresh_async_returns_true_for_existing_key() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        assert!(cache.refresh_async(&1).await);
    }

    #[tokio::test]
    async fn refresh_async_returns_false_for_missing_key() {
        let cache = test_cache();

        assert!(!cache.refresh_async(&1).await);
    }

    #[tokio::test]
    async fn insert_with_ttl_async_enforces_capacity_under_parallel_inserts() {
        let _insert_delay_guard = InsertDelayGuard::enable();
        let cache = Arc::new(TtlCache::new(CacheConfiguration::new(
            Duration::from_mins(1),
            Some(1),
            Some(1),
            Some(CapacityEnforcement::Strict),
        )));
        let start = Arc::new(tokio::sync::Barrier::new(8));

        let handles: Vec<_> = (0..8)
            .map(|key| {
                let cache = Arc::clone(&cache);
                let start = Arc::clone(&start);
                tokio::spawn(async move {
                    start.wait().await;
                    cache.insert_async(key, format!("value{key}")).await
                })
            })
            .collect();

        let mut results = Vec::with_capacity(handles.len());
        for handle in handles {
            results.push(handle.await.unwrap());
        }

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(CacheError::CapacityExceeded)))
                .count(),
            7
        );
        assert_eq!(cache.len(), 1);
    }

    #[tokio::test]
    async fn evict_expired_async_removes_expired_entries() {
        let cache = test_cache();
        cache.insert_async(1, "value1".to_owned()).await.unwrap();
        cache.insert_async(2, "value2".to_owned()).await.unwrap();

        // Manually expire the first entry
        cache
            .items
            .update_async(&1, |_, entry| {
                entry.expire();
            })
            .await;

        let removed = cache.evict_expired_async().await;

        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].as_str(), "value1");
        assert!(cache.get_async(&1).await.is_none());
        assert!(cache.get_async(&2).await.is_some());
    }

    #[tokio::test]
    async fn duplicate_key_async_insertion_returns_error() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        let result = cache.insert_async(1, "new_value".to_owned()).await;

        assert!(matches!(result, Err(CacheError::DuplicateKey)));
        assert_eq!(cache.get_async(&1).await.unwrap().as_str(), "value");
    }

    #[tokio::test]
    async fn upsert_async_allows_duplicate_keys() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        cache.upsert_async(1, "new_value".to_owned()).await.unwrap();

        assert_eq!(cache.get_async(&1).await.unwrap().as_str(), "new_value");
    }

    #[tokio::test]
    async fn upsert_async_enforces_capacity_for_new_keys() {
        let cache = TtlCache::new(CacheConfiguration::new(
            Duration::from_mins(1),
            Some(1),
            Some(1),
            Some(CapacityEnforcement::Strict),
        ));
        cache.upsert_async(1, "value".to_owned()).await.unwrap();

        let result = cache.upsert_async(2, "other".to_owned()).await;

        assert!(matches!(result, Err(CacheError::CapacityExceeded)));
        assert_eq!(cache.len(), 1);
    }

    #[tokio::test]
    async fn contains_key_async_reflects_membership() {
        let cache = test_cache();
        cache.insert_async(1, "value".to_owned()).await.unwrap();

        assert!(cache.contains_key_async(&1).await);
        assert!(!cache.contains_key_async(&2).await);
    }

    #[tokio::test]
    async fn clear_async_empties_cache() {
        let cache = test_cache();
        cache.insert_async(1, "value1".to_owned()).await.unwrap();
        cache.insert_async(2, "value2".to_owned()).await.unwrap();

        cache.clear_async().await;

        assert_eq!(cache.len(), 0);
        assert!(cache.get_async(&1).await.is_none());
        assert!(cache.get_async(&2).await.is_none());
    }
}
