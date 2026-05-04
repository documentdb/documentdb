/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/collections/error.rs
 *
 *-------------------------------------------------------------------------
 */

/// Error type for cache operations
#[derive(Debug, Clone)]
pub enum CacheError {
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "This may not be used in all configurations")
    )]
    DuplicateKey,
    CapacityExceeded,
}

impl std::fmt::Display for CacheError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateKey => write!(f, "Duplicate key insertion attempted in cache"),
            Self::CapacityExceeded => write!(f, "Cache has reached maximum capacity"),
        }
    }
}

impl std::error::Error for CacheError {}
