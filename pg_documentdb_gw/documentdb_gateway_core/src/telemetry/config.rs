/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/config.rs
 *
 * Shared telemetry configuration types and helpers.
 * Follows SetupConfiguration pattern: accessor methods resolve JSON > env > default.
 *
 *-------------------------------------------------------------------------
 */

/// Provider-neutral telemetry capabilities resolved by the active adapter.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TelemetrySettings {
    request_metrics_enabled: bool,
}

impl TelemetrySettings {
    #[must_use]
    pub const fn new(request_metrics_enabled: bool) -> Self {
        Self {
            request_metrics_enabled,
        }
    }

    #[must_use]
    pub const fn request_metrics_enabled(self) -> bool {
        self.request_metrics_enabled
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_expose_adapter_resolved_capabilities() {
        let settings = TelemetrySettings::new(true);
        assert!(settings.request_metrics_enabled());
    }
}
