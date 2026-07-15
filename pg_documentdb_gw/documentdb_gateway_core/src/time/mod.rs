/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/time/mod.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::OnceLock;

use tokio::time::{Duration, Instant};

mod epoch_clock;

pub use epoch_clock::EpochClock;

/// Process-wide startup instant, captured once as early as possible in `main()`.
pub static STARTUP_INSTANT: OnceLock<Instant> = OnceLock::new();

#[must_use]
pub fn instant_to_u64(instant: Instant) -> u64 {
    u64::try_from(instant.duration_since(EpochClock::epoch()).as_nanos()).unwrap_or(u64::MAX)
}

#[must_use]
pub fn u64_to_instant(nanos: u64) -> Instant {
    EpochClock::epoch() + Duration::from_nanos(nanos)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[expect(
        clippy::use_debug,
        reason = "we want to print the actual drift value in case of failure"
    )]
    #[test]
    fn test_instant_to_u64_with_roundtrip_preserves_value() {
        let _ = EpochClock::epoch();
        let now = Instant::now();
        let encoded = instant_to_u64(now);
        let decoded = u64_to_instant(encoded);

        let drift = if decoded > now {
            decoded - now
        } else {
            now - decoded
        };

        // Don't go above 100 microseconds since in this case you might have an
        // issue either with performance or with the precision of the encoding.
        // In practice, we expect this to be in the low microseconds or even nanoseconds, but
        // we see 20-30 microseconds in CI, so we use a more generous threshold to avoid flakes.
        println!("Duration for test_instant_to_u64_with_roundtrip_preserves_value: {drift:?}");
        assert!(drift < Duration::from_micros(100));
    }

    #[test]
    fn test_instant_to_u64_with_ordered_instants_preserves_ordering() {
        let _ = EpochClock::epoch();
        let first = Instant::now();
        let second = first + Duration::from_millis(50);

        assert!(instant_to_u64(second) > instant_to_u64(first));
    }

    #[tokio::test]
    async fn same_value_two_threads() {
        // Do NOT pre-initialise — both tasks race to call epoch() for the first time.
        let handle1 = tokio::spawn(async { EpochClock::epoch() });

        // We wait 100 milliseconds to increase the likelihood that the second task will trigger the initialization.
        tokio::time::sleep(Duration::from_millis(100)).await;
        let handle2 = tokio::spawn(async { EpochClock::epoch() });

        let epoch1 = handle1.await.unwrap();
        let epoch2 = handle2.await.unwrap();

        // Both tasks must observe the exact same epoch Instant regardless of which one
        // triggered initialisation.
        assert_eq!(epoch1, epoch2, "threads observed different epoch values");
    }

    #[tokio::test]
    async fn almost_now_two_threads() {
        // Do NOT pre-initialise — both tasks race to call almost_now() for the first time.
        let handle1 = tokio::spawn(async { EpochClock::almost_now() });

        // We wait 100 milliseconds to ensure that the 50ms update interval of the almost_now clock has passed.
        tokio::time::sleep(Duration::from_millis(100)).await;
        let handle2 = tokio::spawn(async { EpochClock::almost_now() });

        let first_instant = handle1.await.unwrap();
        let second_instant = handle2.await.unwrap();
        let approx_drift = second_instant.duration_since(first_instant);

        // The drift between the two almost_now instants should be less than 150 milliseconds.
        // This should rarely happen, but we allow up to 150 milliseconds to account for scheduling delays in CI.
        assert!(
            approx_drift <= Duration::from_millis(150),
            "drift between almost_now instants is too large: {approx_drift:?}"
        );
    }
}
