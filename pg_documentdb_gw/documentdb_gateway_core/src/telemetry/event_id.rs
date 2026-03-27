/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/event_id.rs
 *
 *-------------------------------------------------------------------------
 */

#[repr(u64)]
#[derive(Copy, Clone, Debug)]
pub enum EventId {
    Default = 1,
    Probe = 2000,
    RequestTrace = 2001,
    ConnectionPool = 2002,
    // Values 2101 to 2199 are reserved for different types of user request failures.
    RequestFailure = 2101,
}

impl EventId {
    #[must_use]
    pub const fn code(self) -> u64 {
        self as u64
    }
}
