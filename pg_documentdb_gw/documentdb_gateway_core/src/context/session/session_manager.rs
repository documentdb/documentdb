/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/session/session_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::context::{CursorStore, TransactionStore};

#[derive(Debug)]
pub struct SessionManager {
    transactions: TransactionStore,
    cursors: CursorStore,
}

impl SessionManager {
    #[must_use]
    pub const fn new(transactions: TransactionStore, cursors: CursorStore) -> Self {
        Self {
            transactions,
            cursors,
        }
    }

    #[must_use]
    pub const fn transactions(&self) -> &TransactionStore {
        &self.transactions
    }

    #[must_use]
    pub const fn cursors(&self) -> &CursorStore {
        &self.cursors
    }
}
