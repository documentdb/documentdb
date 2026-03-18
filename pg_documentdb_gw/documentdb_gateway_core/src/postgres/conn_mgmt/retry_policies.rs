/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/retry_policies.rs
 *
 * Retry policies for database operations with different backoff strategies.
 *
 *-------------------------------------------------------------------------
 */

use rand::Rng;
use tokio::time::Duration;

/// For the short retry policy we use the Decorrelated Jitter backoff algorithm which generates
/// an exponential evenly distribution with some randomness in it. Since here we are going to
/// wait a short period overall, say 2-4 seconds, we want short intervals, but we want them to
/// be growing with some randomness in it.
#[derive(Debug)]
pub struct ShortRetryPolicy {
    max_retry_count: u32,
    min_retry_delay: Duration,
    max_retry_delay: Duration,
    current_retry: u32,
    current_interval_delay: Duration,
    previous_interval: f64,
}

impl ShortRetryPolicy {
    /// Scaling factors for the `DecorrelatedJitter` algorithm.
    const P_FACTOR: f64 = 4.0;
    const RP_SCALING_FACTOR: f64 = 1.0 / 1.4;
    /// Upper-bound to prevent overflow beyond `Duration::MAX`.
    const MAX_DURATION_NANOS: f64 = f64::MAX - 1000.0;

    /// Creates a new `ShortRetryPolicy` with the specified parameters.
    ///
    /// # Arguments
    ///
    /// * `max_retry_count` - Maximum number of retries before giving up.
    /// * `min_retry_delay` - Minimum delay between retries.
    /// * `max_retry_delay` - Maximum delay between retries.
    pub const fn new(
        max_retry_count: u32,
        min_retry_delay: Duration,
        max_retry_delay: Duration,
    ) -> Self {
        Self {
            max_retry_count,
            min_retry_delay,
            max_retry_delay,
            current_retry: 0,
            current_interval_delay: Duration::ZERO,
            previous_interval: 0.0,
        }
    }

    /// Calculates the next retry interval and increments the retry count.
    ///
    /// # Returns
    ///
    /// `None` if the retry count is exhausted. Otherwise, returns the `Duration`
    /// representing the interval to wait before the next retry.
    #[expect(
        clippy::cast_precision_loss,
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        reason = "The precision loss from f64 to u64 is acceptable for our delay calculations, which are in milliseconds and do not require high precision."
    )]
    pub fn next_interval(&mut self) -> Option<Duration> {
        if self.current_retry >= self.max_retry_count {
            return None;
        }

        if self.current_interval_delay != self.max_retry_delay {
            let t = f64::from(self.current_retry) + rand::thread_rng().gen_range(0.0..1.0);
            let next = t.exp2() * (Self::P_FACTOR * t).sqrt().tanh();

            let formula_intrinsic_value = next - self.previous_interval;
            self.previous_interval = next;

            let interval_nanos = (formula_intrinsic_value
                * Self::RP_SCALING_FACTOR
                * self.min_retry_delay.as_nanos() as f64)
                .min(Self::MAX_DURATION_NANOS);

            let current_interval = Duration::from_nanos(interval_nanos as u64);
            self.current_interval_delay = if current_interval > self.max_retry_delay {
                self.max_retry_delay
            } else {
                current_interval
            };
        }

        self.current_retry += 1;
        Some(self.current_interval_delay)
    }
}

/// For the long retry policy we use the Aws `DecorrelatedJitterBackoff` which generates an even
/// distribution of backoff intervals between the min value and the max value provided. We want
/// that for the long retry policy as we don't need an exponential jittered backoff here, since
/// we don't want to have very long or very short retry intervals.
///
/// This is useful for waiting on longer operations, e.g., the standby node to be promoted to
/// primary, so in that time the database is read-only and it could take from as little as
/// 5 seconds up to 90 seconds.
///
/// This algorithm is based on:
/// <https://github.com/Polly-Contrib/Polly.Contrib.WaitAndRetry/blob/7596d2dacf22d88bbd814bc49c28424fb6e921e9/src/Polly.Contrib.WaitAndRetry/Backoff.AwsDecorrelatedJitter.cs#L30>
///
/// However we implement it here to avoid using iterators which could cause allocations and be
/// slower in performance for our needs.
#[derive(Debug)]
pub struct LongRetryPolicy {
    max_retry_count: u32,
    min_retry_delay: Duration,
    max_retry_delay: Duration,
    current_retry: u32,
    current_interval_delay: Duration,
}

impl LongRetryPolicy {
    /// Creates a new `LongRetryPolicy` with the specified parameters.
    ///
    /// # Arguments
    ///
    /// * `max_retry_count` - Maximum number of retries before giving up.
    /// * `min_retry_delay` - Minimum delay between retries.
    /// * `max_retry_delay` - Maximum delay between retries.
    pub const fn new(
        max_retry_count: u32,
        min_retry_delay: Duration,
        max_retry_delay: Duration,
    ) -> Self {
        Self {
            max_retry_count,
            min_retry_delay,
            max_retry_delay,
            current_retry: 0,
            current_interval_delay: min_retry_delay,
        }
    }

    /// Calculates the next retry interval and increments the retry count.
    ///
    /// # Returns
    ///
    /// `None` if the retry count is exhausted. Otherwise, returns the `Duration`
    /// representing the interval to wait before the next retry.
    #[expect(
        clippy::cast_precision_loss,
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        reason = "The precision loss from f64 to u64 is acceptable for our delay calculations, which are in milliseconds and do not require high precision."
    )]
    pub fn next_interval(&mut self) -> Option<Duration> {
        if self.current_retry >= self.max_retry_count {
            return None;
        }

        let ceiling_ms = self
            .max_retry_delay
            .as_millis()
            .min(self.current_interval_delay.as_millis() * 3);

        let min_total_ms = self.min_retry_delay.as_millis();

        // Calculate the interval which is a random value that is greater or equal
        // to the min_retry_delay and less than max_retry_delay.
        let ms = if min_total_ms == ceiling_ms {
            min_total_ms as f64
        } else {
            ((ceiling_ms - min_total_ms) as f64)
                .mul_add(rand::thread_rng().gen_range(0.0..1.0), min_total_ms as f64)
        };

        self.current_interval_delay = Duration::from_millis(ms as u64);
        self.current_retry += 1;
        Some(self.current_interval_delay)
    }
}

/// Builder for creating retry policies with predefined default configurations.
///
/// This struct provides factory methods to create `ShortRetryPolicy` and `LongRetryPolicy`
/// instances with the standard configuration constants used across the system.
#[derive(Debug, Clone, Copy, Default)]
pub struct RetryPolicyBuilder;

impl RetryPolicyBuilder {
    // Short retry policy constants
    const SHORT_MAX_RETRY_COUNT: u32 = 10;
    const SHORT_MIN_RETRY_DELAY_MS: u64 = 10;
    const SHORT_MAX_RETRY_DELAY_MS: u64 = 1000;

    // Long retry policy constants
    const LONG_MAX_RETRY_COUNT: u32 = 25;
    const LONG_MIN_RETRY_DELAY_MS: u64 = 2500;
    const LONG_MAX_RETRY_DELAY_MS: u64 = 7500;

    /// Builds a new `ShortRetryPolicy` with the default configuration.
    ///
    /// Default configuration:
    /// - Max retry count: 10
    /// - Min retry delay: 10ms
    /// - Max retry delay: 1000ms
    pub const fn build_short() -> ShortRetryPolicy {
        ShortRetryPolicy::new(
            Self::SHORT_MAX_RETRY_COUNT,
            Duration::from_millis(Self::SHORT_MIN_RETRY_DELAY_MS),
            Duration::from_millis(Self::SHORT_MAX_RETRY_DELAY_MS),
        )
    }

    /// Builds a new `LongRetryPolicy` with the default configuration.
    ///
    /// Default configuration:
    /// - Max retry count: 25
    /// - Min retry delay: 2500ms
    /// - Max retry delay: 7500ms
    pub const fn build_long() -> LongRetryPolicy {
        LongRetryPolicy::new(
            Self::LONG_MAX_RETRY_COUNT,
            Duration::from_millis(Self::LONG_MIN_RETRY_DELAY_MS),
            Duration::from_millis(Self::LONG_MAX_RETRY_DELAY_MS),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_retry_policy_returns_none_when_exhausted() {
        let mut policy =
            ShortRetryPolicy::new(3, Duration::from_millis(100), Duration::from_millis(1000));

        assert!(policy.next_interval().is_some());
        assert!(policy.next_interval().is_some());
        assert!(policy.next_interval().is_some());

        assert!(policy.next_interval().is_none());
    }

    #[test]
    fn short_retry_policy_respects_max_delay() {
        let max_delay = Duration::from_millis(500);
        let mut policy = ShortRetryPolicy::new(10, Duration::from_millis(100), max_delay);

        for _ in 0..10 {
            if let Some(interval) = policy.next_interval() {
                assert!(interval <= max_delay);
            }
        }
    }

    #[test]
    fn long_retry_policy_returns_none_when_exhausted() {
        let mut policy =
            LongRetryPolicy::new(3, Duration::from_millis(100), Duration::from_millis(1000));

        assert!(policy.next_interval().is_some());
        assert!(policy.next_interval().is_some());
        assert!(policy.next_interval().is_some());

        assert!(policy.next_interval().is_none());
    }

    #[test]
    fn long_retry_policy_respects_bounds() {
        let min_delay = Duration::from_millis(100);
        let max_delay = Duration::from_millis(500);
        let mut policy = LongRetryPolicy::new(10, min_delay, max_delay);

        for _ in 0..10 {
            if let Some(interval) = policy.next_interval() {
                assert!(interval >= min_delay);
                assert!(interval <= max_delay);
            }
        }
    }

    #[test]
    fn builder_creates_short_policy_with_correct_defaults() {
        let mut policy = RetryPolicyBuilder::build_short();

        // Should allow 10 retries
        for _ in 0..10 {
            assert!(policy.next_interval().is_some());
        }
        assert!(policy.next_interval().is_none());
    }

    #[test]
    fn builder_creates_long_policy_with_correct_defaults() {
        let mut policy = RetryPolicyBuilder::build_long();

        // Should allow 25 retries
        for _ in 0..25 {
            assert!(policy.next_interval().is_some());
        }
        assert!(policy.next_interval().is_none());
    }

    #[test]
    fn builder_short_policy_respects_max_delay() {
        let mut policy = RetryPolicyBuilder::build_short();
        let max_delay = Duration::from_millis(1000);

        for _ in 0..10 {
            if let Some(interval) = policy.next_interval() {
                assert!(interval <= max_delay);
            }
        }
    }

    #[test]
    fn builder_long_policy_respects_bounds() {
        let mut policy = RetryPolicyBuilder::build_long();
        let min_delay = Duration::from_millis(2500);
        let max_delay = Duration::from_millis(7500);

        for _ in 0..25 {
            if let Some(interval) = policy.next_interval() {
                assert!(interval >= min_delay);
                assert!(interval <= max_delay);
            }
        }
    }
}
