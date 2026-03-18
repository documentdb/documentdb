/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/shutdown_controller.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::LazyLock;
use tokio_util::sync::CancellationToken;

#[derive(Debug)]
pub struct ShutdownController {
    token: CancellationToken,
}

// Global singleton
pub static SHUTDOWN_CONTROLLER: LazyLock<ShutdownController> =
    LazyLock::new(|| ShutdownController {
        token: CancellationToken::new(),
    });

impl ShutdownController {
    #[must_use]
    pub fn token(&self) -> CancellationToken {
        self.token.clone()
    }

    pub fn shutdown(&self) {
        self.token.cancel();
    }
}
