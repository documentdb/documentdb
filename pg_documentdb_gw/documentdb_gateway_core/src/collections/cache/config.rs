/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/collections/cache/config.rs
 *
 *-------------------------------------------------------------------------
 */

use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapacityEnforcement {
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "This enforcement policy may not be used in all configurations"
        )
    )]
    Strict,
    Relaxed,
}

#[derive(Debug)]
pub struct CacheConfiguration {
    default_ttl: Duration,
    max_capacity: usize,
    initial_capacity: usize,
    capacity_enforcement: CapacityEnforcement,
}

impl CacheConfiguration {
    /// # Panics
    ///
    /// Panics if `initial_capacity` is greater than `max_capacity` when a non-zero maximum is
    /// configured.
    #[must_use]
    pub fn new(
        default_ttl: Duration,
        initial_capacity: Option<usize>,
        max_capacity: Option<usize>,
        capacity_enforcement: Option<CapacityEnforcement>,
    ) -> Self {
        let configuration = Self {
            default_ttl,
            max_capacity: max_capacity.unwrap_or(0),
            initial_capacity: initial_capacity.unwrap_or(1024),
            capacity_enforcement: capacity_enforcement.unwrap_or(CapacityEnforcement::Relaxed),
        };

        if configuration.max_capacity > 0
            && configuration.initial_capacity > configuration.max_capacity
        {
            panic!("Initial capacity cannot be greater than max capacity: initial_capacity={} max_capacity={}", configuration.initial_capacity, configuration.max_capacity);
        }

        configuration
    }

    #[must_use]
    pub fn with_ttl(default_ttl: Duration) -> Self {
        Self::new(default_ttl, None, None, None)
    }

    #[must_use]
    pub const fn default_ttl(&self) -> Duration {
        self.default_ttl
    }

    #[must_use]
    pub const fn max_capacity(&self) -> usize {
        self.max_capacity
    }

    #[must_use]
    pub const fn initial_capacity(&self) -> usize {
        self.initial_capacity
    }

    /// Returns the capacity enforcement policy for the cache. If the enforcement is `Strict`,
    /// the cache will not exceed the `max_capacity`. If the enforcement is `Relaxed`, the cache
    /// may temporarily exceed the `max_capacity`.
    #[must_use]
    pub const fn max_capacity_enforcement(&self) -> CapacityEnforcement {
        self.capacity_enforcement
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_configuration_initial_capacity_minimum() {
        let config = CacheConfiguration::new(
            Duration::from_secs(60),
            Some(512),
            Some(1024),
            Some(CapacityEnforcement::Relaxed),
        );

        assert_eq!(config.initial_capacity(), 512);
    }

    #[test]
    #[should_panic(expected = "Initial capacity cannot be greater than max capacity")]
    fn test_cache_configuration_initial_capacity_greater_than_max_capacity() {
        let _config = CacheConfiguration::new(
            Duration::from_secs(60),
            Some(2048),
            Some(1024),
            Some(CapacityEnforcement::Relaxed),
        );
    }

    #[test]
    fn test_cache_configuration_initial_capacity_equal_to_max_capacity() {
        let _config = CacheConfiguration::new(
            Duration::from_secs(60),
            Some(1),
            Some(1),
            Some(CapacityEnforcement::Relaxed),
        );
    }
}
