//! Caching of prepared statements.

use std::{
    borrow::Cow,
    collections::HashMap,
    fmt,
    future::Future,
    sync::{Arc, Mutex, RwLock, Weak},
};

use tokio::sync::OnceCell;
use tokio_postgres::{Client as PgClient, Error, Statement, types::Type};

/// Structure holding a reference to all [`StatementCache`]s and providing
/// access for clearing all caches and removing single statements from them.
#[derive(Default, Debug)]
pub struct StatementCaches {
    caches: Mutex<Vec<Weak<StatementCache>>>,
}

impl StatementCaches {
    pub(crate) fn attach(&self, cache: &Arc<StatementCache>) {
        let cache = Arc::downgrade(cache);
        self.caches.lock().unwrap().push(cache);
    }

    pub(crate) fn detach(&self, cache: &Arc<StatementCache>) {
        let cache = Arc::downgrade(cache);
        self.caches.lock().unwrap().retain(|sc| !sc.ptr_eq(&cache));
    }

    /// Clears [`StatementCache`] of all connections which were handed out by a
    /// [`Manager`](crate::Manager).
    pub fn clear(&self) {
        let caches = self.caches.lock().unwrap();
        for cache in caches.iter() {
            if let Some(cache) = cache.upgrade() {
                cache.clear();
            }
        }
    }

    /// Removes statement from all caches which were handed out by a
    /// [`Manager`](crate::Manager).
    pub fn remove(&self, query: &str, types: &[Type]) {
        let caches = self.caches.lock().unwrap();
        for cache in caches.iter() {
            if let Some(cache) = cache.upgrade() {
                drop(cache.remove(query, types));
            }
        }
    }
}

/// Key of a [`StatementCacheInner`]: a query plus the types of its parameters.
///
/// Storing [`Cow`]s lets the map own its keys while lookups pass a key borrowing
/// from the caller's `&str` and `&[Type]`, so a cache hit allocates nothing.
#[derive(Debug, Eq, Hash, PartialEq)]
struct StatementCacheKey<'a> {
    query: Cow<'a, str>,
    types: Cow<'a, [Type]>,
}

impl<'a> StatementCacheKey<'a> {
    /// Builds a key borrowing from `query` and `types`, as lookups use.
    fn borrowed(query: &'a str, types: &'a [Type]) -> Self {
        Self {
            query: Cow::Borrowed(query),
            types: Cow::Borrowed(types),
        }
    }

    /// Builds an owned key, as insertion and removal need.
    fn owned(query: &str, types: &[Type]) -> StatementCacheKey<'static> {
        StatementCacheKey {
            query: Cow::Owned(query.to_owned()),
            types: Cow::Owned(types.to_owned()),
        }
    }
}

/// The inside of a [`StatementCache`]: a keyed map of lazily prepared values.
///
/// Every key maps to a [`OnceCell`] that is initialized at most once. Concurrent
/// callers asking for the same key therefore share one initialization: the first
/// one runs it while the others wait, and if it returns an error or is
/// cancelled, one of the waiters takes over.
///
/// The cells are held behind an [`Arc`] so that an initialization in flight
/// keeps working on its own cell even if [`clear()`](Self::clear) or
/// [`remove()`](Self::remove) evicts it in the meantime. Such a detached cell is
/// no longer reachable through the map, so an eviction can never be undone by an
/// initialization that started before it.
///
/// This is generic over the value type `V` purely so that it can be tested
/// without a live PostgreSQL — [`Statement`] has no public constructor, so a
/// test cannot build one. It is not meant to be reused for anything else;
/// [`StatementCache`] instantiates it with `V = Statement`.
struct StatementCacheInner<V> {
    map: RwLock<HashMap<StatementCacheKey<'static>, Arc<OnceCell<V>>>>,
}

impl<V: Clone> StatementCacheInner<V> {
    fn new() -> Self {
        Self {
            map: RwLock::new(HashMap::new()),
        }
    }

    /// Returns the number of initialized values in the map.
    ///
    /// Cells that are still being initialized (or whose initialization failed)
    /// are uninitialized and never count towards the size.
    fn size(&self) -> usize {
        self.map
            .read()
            .unwrap()
            .values()
            .filter(|cell| cell.initialized())
            .count()
    }

    /// Removes all entries.
    fn clear(&self) {
        self.map.write().unwrap().clear();
    }

    /// Removes a value from the map.
    ///
    /// Removing a cell that is not initialized yet returns `None`.
    ///
    /// Unlike a lookup this has to build an owned key: removal needs a `&mut`
    /// borrow of the map, and `&mut T` is invariant in `T`, so the `'static`
    /// keys of the map cannot be viewed as shorter-lived borrowed ones here.
    /// Eviction is the cold path, so that allocation does not matter.
    fn remove(&self, query: &str, types: &[Type]) -> Option<V> {
        let cell = self
            .map
            .write()
            .unwrap()
            .remove(&StatementCacheKey::owned(query, types))?;
        cell.get().cloned()
    }

    /// Returns the cell for `query`/`types`, inserting an empty one if the key
    /// is not present yet.
    fn cell(&self, query: &str, types: &[Type]) -> Arc<OnceCell<V>> {
        // Fast path: the key is already known, so a read lock suffices and no
        // owned key has to be built.
        if let Some(cell) = self
            .map
            .read()
            .unwrap()
            .get(&StatementCacheKey::borrowed(query, types))
        {
            return cell.clone();
        }
        // Slow path: allocate the owned key and insert a cell, unless another
        // task beat us to it while we waited for the write lock.
        self.map
            .write()
            .unwrap()
            .entry(StatementCacheKey::owned(query, types))
            .or_default()
            .clone()
    }

    /// Returns the value for `query`/`types`, initializing it via `init` if it
    /// is not present yet.
    ///
    /// Concurrent callers for the same key are coalesced so that `init` runs at
    /// most once per key and successful initialization. If `init` returns an
    /// error the cell is left uninitialized, so a subsequent call retries.
    async fn get_or_try_init<F, Fut, E>(&self, query: &str, types: &[Type], init: F) -> Result<V, E>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>>,
    {
        self.cell(query, types).get_or_try_init(init).await.cloned()
    }
}

/// Representation of a cache of [`Statement`]s.
///
/// [`StatementCache`] is bound to one [`Client`](crate::Client), and
/// [`Statement`]s generated by that [`Client`](crate::Client) must not be used
/// with other [`Client`](crate::Client)s.
///
/// Preparing the same statement from several tasks at once is coalesced: one of
/// them sends a `PREPARE` to the database while the others wait for its result,
/// so a burst of concurrent requests for an uncached statement costs a single
/// round trip rather than one per task. If that preparation fails or its task is
/// cancelled, one of the waiting tasks starts a fresh one instead of failing
/// along with it, and nothing is cached until a preparation succeeds.
///
/// It can be used like that:
/// ```rust,ignore
/// let client = pool.get().await?;
/// let stmt = client
///     .statement_cache
///     .prepare(&client, "SELECT 1")
///     .await;
/// let rows = client.query(stmt, &[]).await?;
/// ...
/// ```
///
/// Normally, you probably want to use the
/// [`ClientWrapper::prepare_cached()`](crate::ClientWrapper::prepare_cached)
/// and
/// [`ClientWrapper::prepare_typed_cached()`](crate::ClientWrapper::prepare_typed_cached)
/// methods instead (or the similar ones on [`Transaction`](crate::Transaction)).
pub struct StatementCache {
    inner: StatementCacheInner<Statement>,
}

impl fmt::Debug for StatementCache {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StatementCache")
            .field("size", &self.inner.size())
            .finish()
    }
}

impl StatementCache {
    pub(crate) fn new() -> Self {
        Self {
            inner: StatementCacheInner::new(),
        }
    }

    /// Returns current size of this [`StatementCache`].
    pub fn size(&self) -> usize {
        self.inner.size()
    }

    /// Clears this [`StatementCache`].
    ///
    /// **Important:** This only clears the [`StatementCache`] of one
    /// [`Client`](crate::Client) instance. If you want to clear the
    /// [`StatementCache`] of all [`Client`](crate::Client)s
    /// you should be calling `pool.manager().statement_caches.clear()` instead.
    pub fn clear(&self) {
        self.inner.clear();
    }

    /// Removes a [`Statement`] from this [`StatementCache`].
    ///
    /// **Important:** This only removes a [`Statement`] from one
    /// [`Client`](crate::Client) cache. If you want to remove a [`Statement`]
    /// from all
    /// [`StatementCaches`] you should be calling
    /// `pool.manager().statement_caches.remove()` instead.
    pub fn remove(&self, query: &str, types: &[Type]) -> Option<Statement> {
        self.inner.remove(query, types)
    }

    /// Creates a new prepared [`Statement`] using this [`StatementCache`], if
    /// possible.
    ///
    /// See [`tokio_postgres::Client::prepare()`].
    pub async fn prepare(&self, client: &PgClient, query: &str) -> Result<Statement, Error> {
        self.prepare_typed(client, query, &[]).await
    }

    /// Creates a new prepared [`Statement`] with specifying its [`Type`]s
    /// explicitly using this [`StatementCache`], if possible.
    ///
    /// See [`tokio_postgres::Client::prepare_typed()`].
    pub async fn prepare_typed(
        &self,
        client: &PgClient,
        query: &str,
        types: &[Type],
    ) -> Result<Statement, Error> {
        self.inner
            .get_or_try_init(query, types, || client.prepare_typed(query, types))
            .await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use super::*;

    /// A miss runs `init` once and caches the value; a subsequent call for the
    /// same key is a hit and does not run `init` again.
    #[tokio::test]
    async fn initializes_on_miss_and_caches() {
        let cache = StatementCacheInner::<u32>::new();
        let calls = AtomicUsize::new(0);

        let first = cache
            .get_or_try_init("q", &[], || async {
                let _ = calls.fetch_add(1, Ordering::Relaxed);
                Ok::<u32, ()>(42)
            })
            .await
            .unwrap();
        assert_eq!(first, 42);
        assert_eq!(cache.size(), 1);

        // The second closure returns a different value; since the key is cached
        // it must never run, and the original value is returned.
        let second = cache
            .get_or_try_init("q", &[], || async {
                let _ = calls.fetch_add(1, Ordering::Relaxed);
                Ok::<u32, ()>(99)
            })
            .await
            .unwrap();
        assert_eq!(second, 42);
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert_eq!(cache.size(), 1);
    }

    /// A key borrowing from the caller's `&str`/`&[Type]` must match the owned
    /// key stored for it, whatever those borrows point at, and the parameter
    /// types are part of the key rather than just the query. No integration test
    /// covers a cache *hit* — they all prepare exactly once — so this is the
    /// only coverage of the borrowed/owned [`Cow`] matching.
    #[tokio::test]
    async fn borrowed_key_matches_stored_owned_key() {
        let cache = StatementCacheInner::<u32>::new();

        // Stored from owned data ...
        let query = String::from("SELECT $1");
        let types = vec![Type::INT4];
        let first = cache
            .get_or_try_init(&query, &types, || async { Ok::<u32, ()>(1) })
            .await
            .unwrap();
        assert_eq!(first, 1);

        // ... and found again from unrelated borrows with the same contents, so
        // the second closure never runs.
        let second = cache
            .get_or_try_init("SELECT $1", &[Type::INT4], || async { Ok::<u32, ()>(2) })
            .await
            .unwrap();
        assert_eq!(second, 1);
        assert_eq!(cache.size(), 1);

        // Same query, different parameter types: a distinct key.
        let other = cache
            .get_or_try_init("SELECT $1", &[Type::TEXT], || async { Ok::<u32, ()>(3) })
            .await
            .unwrap();
        assert_eq!(other, 3);
        assert_eq!(cache.size(), 2);

        // `remove` reaches the entry through a borrowed key too.
        assert_eq!(cache.remove("SELECT $1", &types), Some(1));
        assert_eq!(cache.size(), 1);
    }

    /// Many tasks racing on the same key must all end up on the *same* cell, so
    /// that `init` runs once and everyone observes the same value. The
    /// once-per-cell part is [`OnceCell`]'s job; what is tested here is the
    /// read-lock-then-write-lock lookup in [`StatementCacheInner::cell()`],
    /// which is where a second cell could sneak in.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn coalesces_concurrent_initializers() {
        // Repeat with fresh caches to shake out ordering-dependent races.
        for _ in 0..20 {
            let cache = Arc::new(StatementCacheInner::<u32>::new());
            let calls = Arc::new(AtomicUsize::new(0));

            let handles = (0..128)
                .map(|_| {
                    let cache = cache.clone();
                    let calls = calls.clone();
                    tokio::spawn(async move {
                        cache
                            .get_or_try_init("q", &[], || async {
                                let _ = calls.fetch_add(1, Ordering::Relaxed);
                                // Widen the race window so multiple tasks pile
                                // up on the semaphore.
                                tokio::task::yield_now().await;
                                Ok::<u32, ()>(7)
                            })
                            .await
                            .unwrap()
                    })
                })
                .collect::<Vec<_>>();

            for handle in handles {
                assert_eq!(handle.await.unwrap(), 7);
            }
            assert_eq!(calls.load(Ordering::Relaxed), 1);
            assert_eq!(cache.size(), 1);
        }
    }

    /// Distinct keys are initialized independently, once each.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn distinct_keys_initialized_independently() {
        let cache = Arc::new(StatementCacheInner::<u32>::new());
        let calls = Arc::new(AtomicUsize::new(0));

        let handles = (0..16u32)
            .map(|i| {
                let cache = cache.clone();
                let calls = calls.clone();
                tokio::spawn(async move {
                    let query = format!("q{i}");
                    cache
                        .get_or_try_init(&query, &[], || async {
                            let _ = calls.fetch_add(1, Ordering::Relaxed);
                            Ok::<u32, ()>(i)
                        })
                        .await
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();

        for handle in handles {
            let _ = handle.await.unwrap();
        }
        assert_eq!(calls.load(Ordering::Relaxed), 16);
        assert_eq!(cache.size(), 16);
    }

    /// A leftover uninitialized cell never counts towards the size, `remove` of
    /// such a key returns `None`, and initializing a value into it counts
    /// exactly once.
    #[tokio::test]
    async fn size_accounting_with_uninitialized_cells() {
        let cache = StatementCacheInner::<u32>::new();

        // A failed initialization leaves an uninitialized cell behind.
        let _ = cache
            .get_or_try_init("q", &[], || async { Err::<u32, ()>(()) })
            .await;
        assert_eq!(cache.size(), 0);

        // Removing a key whose cell is uninitialized is a no-op for the size.
        assert_eq!(cache.remove("q", &[]), None);
        assert_eq!(cache.size(), 0);

        // Initializing a value counts once.
        let value = cache
            .get_or_try_init("q", &[], || async { Ok::<u32, ()>(1) })
            .await
            .unwrap();
        assert_eq!(value, 1);
        assert_eq!(cache.size(), 1);

        // Removing the ready value decrements back to zero.
        assert_eq!(cache.remove("q", &[]), Some(1));
        assert_eq!(cache.size(), 0);
    }

    /// `clear` empties the cache and resets the size; afterwards keys are misses
    /// again.
    #[tokio::test]
    async fn clear_resets() {
        let cache = StatementCacheInner::<u32>::new();

        for i in 0..5u32 {
            let query = format!("q{i}");
            let _ = cache
                .get_or_try_init(&query, &[], || async { Ok::<u32, ()>(i) })
                .await
                .unwrap();
        }
        assert_eq!(cache.size(), 5);

        cache.clear();
        assert_eq!(cache.size(), 0);

        // After clearing, a previously cached key is a miss again.
        let calls = AtomicUsize::new(0);
        let _ = cache
            .get_or_try_init("q0", &[], || async {
                let _ = calls.fetch_add(1, Ordering::Relaxed);
                Ok::<u32, ()>(0)
            })
            .await
            .unwrap();
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert_eq!(cache.size(), 1);
    }

    /// An initialization that started before a `clear` must not resurrect the
    /// cleared entry when it finishes afterwards.
    #[tokio::test(flavor = "current_thread")]
    async fn clear_during_initialization_does_not_resurrect() {
        assert_eq!(evict_during_initialization(|cache| cache.clear()).await, 1);
    }

    /// Same for a targeted `remove`, which is the case that actually matters:
    /// removing a statement means it went stale, so an initialization still in
    /// flight must not put it back.
    #[tokio::test(flavor = "current_thread")]
    async fn remove_during_initialization_does_not_resurrect() {
        assert_eq!(
            evict_during_initialization(|cache| {
                // The value is not ready yet, so there is nothing to hand back.
                assert_eq!(cache.remove("q", &[]), None);
            })
            .await,
            1
        );
    }

    /// Runs `evict` while an initialization for `"q"` is in flight, then lets
    /// that initialization finish and returns the value a subsequent lookup
    /// observes.
    async fn evict_during_initialization(evict: impl FnOnce(&StatementCacheInner<u32>)) -> u32 {
        use tokio::sync::oneshot;

        let cache = Arc::new(StatementCacheInner::<u32>::new());
        let (gate_tx, gate_rx) = oneshot::channel::<()>();
        let (started_tx, started_rx) = oneshot::channel::<()>();

        // Task A blocks inside `init` until we open the gate.
        let task_a = {
            let cache = cache.clone();
            tokio::spawn(async move {
                cache
                    .get_or_try_init("q", &[], || async move {
                        let _ = started_tx.send(());
                        let _ = gate_rx.await;
                        Ok::<u32, ()>(0)
                    })
                    .await
            })
        };

        // Evict the entry while task A is still initializing it, ...
        let _ = started_rx.await;
        assert_eq!(cache.size(), 0);
        evict(&cache);

        // ... then let task A finish. It initializes the cell it holds, which is
        // detached from the map by now.
        let _ = gate_tx.send(());
        assert_eq!(task_a.await.unwrap(), Ok(0));
        assert_eq!(cache.size(), 0);

        // The next caller must not see task A's value.
        cache
            .get_or_try_init("q", &[], || async { Ok::<u32, ()>(1) })
            .await
            .unwrap()
    }
}
