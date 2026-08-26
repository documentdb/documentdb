/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/time/epoch_clock.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, SystemTime},
};

use tokio::{task::JoinHandle, time::Instant};

/// Aborts the tokio background task when dropped.
struct AbortOnDrop {
    handle: JoinHandle<()>,
}

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

impl std::fmt::Debug for AbortOnDrop {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AbortOnDrop").finish()
    }
}

#[derive(Debug, Clone)]
pub struct EpochClockInternal {
    epoch: Instant,
    epoch_seconds: u64,
    coarse_millis: Arc<AtomicU64>,
    coarse_seconds: Arc<AtomicU64>,
    /// `None` when no tokio runtime was available at construction time;
    /// in that case `almost_now*` fall back to `Instant::now()`.
    updater: Option<Arc<AbortOnDrop>>,
}

impl EpochClockInternal {
    #[must_use]
    pub fn new() -> Self {
        Self::from_instant(Instant::now())
    }

    fn instant_to_unix(instant: Instant) -> u64 {
        let now = Instant::now();
        let now_unix = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        now_unix.saturating_sub(now.saturating_duration_since(instant).as_secs())
    }

    #[must_use]
    pub fn from_instant(instant: Instant) -> Self {
        let coarse_millis = Arc::new(AtomicU64::new(0));
        let coarse_seconds = Arc::new(AtomicU64::new(0));

        let updater = spawn_coarse_updater(
            instant,
            Arc::clone(&coarse_millis),
            Arc::clone(&coarse_seconds),
        )
        .map(|handle| Arc::new(AbortOnDrop { handle }));

        Self {
            epoch: instant,
            epoch_seconds: Self::instant_to_unix(instant),
            coarse_millis,
            coarse_seconds,
            updater,
        }
    }

    #[must_use]
    #[inline]
    pub const fn epoch(&self) -> Instant {
        self.epoch
    }

    #[must_use]
    #[inline]
    pub fn almost_now(&self) -> Instant {
        if self.updater.is_some() {
            self.epoch + Duration::from_millis(self.coarse_millis.load(Ordering::Relaxed))
        } else {
            Instant::now()
        }
    }

    #[must_use]
    #[inline]
    pub fn almost_now_timestamp(&self) -> u64 {
        if self.updater.is_some() {
            self.epoch_seconds + self.coarse_seconds.load(Ordering::Relaxed)
        } else {
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
        }
    }
}

/// Spawns the coarse clock updater as a tokio task.
/// Returns `None` if no tokio runtime is available (e.g. in unit tests without `#[tokio::test]`).
fn spawn_coarse_updater(
    epoch: Instant,
    coarse_millis: Arc<AtomicU64>,
    coarse_seconds: Arc<AtomicU64>,
) -> Option<JoinHandle<()>> {
    // `tokio::spawn` requires an active runtime handle. If none is present, fall back gracefully.
    let handle = tokio::runtime::Handle::try_current().ok()?;
    let task = handle.spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(50));
        loop {
            interval.tick().await;
            let millis =
                u64::try_from(Instant::now().duration_since(epoch).as_millis()).unwrap_or(u64::MAX);
            coarse_millis.store(millis, Ordering::Relaxed);
            coarse_seconds.store(millis / 1000, Ordering::Relaxed);
        }
    });
    Some(task)
}

static GLOBAL_CLOCK: std::sync::OnceLock<EpochClockInternal> = std::sync::OnceLock::new();

/// Zero-size handle whose methods delegate to the process-wide `EpochClockInternal`.
/// All threads share the same underlying clock data.
///
/// The global clock is initialised on the first call to any method.
#[derive(Debug)]
pub struct EpochClock;

impl EpochClock {
    fn global() -> &'static EpochClockInternal {
        GLOBAL_CLOCK.get_or_init(EpochClockInternal::new)
    }

    /// `Instant::now()` - this will use a system call and typically use ~20ns
    #[must_use]
    #[inline]
    pub fn now() -> Instant {
        Instant::now()
    }

    /// Coarse-grained `Instant` relative to the epoch and takes ~5ns to call.
    #[must_use]
    #[inline]
    pub fn almost_now() -> Instant {
        Self::global().almost_now()
    }

    /// Returns the epoch `Instant` used by the global clock.
    #[must_use]
    #[inline]
    pub fn epoch() -> Instant {
        Self::global().epoch()
    }

    /// Coarse-grained timestamp in seconds since `UNIX_EPOCH` and takes ~2ns to call.
    #[must_use]
    pub fn almost_now_timestamp() -> u64 {
        Self::global().almost_now_timestamp()
    }
}
