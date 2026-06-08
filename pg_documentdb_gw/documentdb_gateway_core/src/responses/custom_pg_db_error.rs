/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/custom_pg_db_error.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt;

use tokio_postgres::error::SqlState;

#[derive(Debug)]
pub struct CustomPgDbError {
    status_code: SqlState,
}

impl CustomPgDbError {
    #[must_use]
    pub const fn new(status_code: SqlState) -> Self {
        Self { status_code }
    }

    #[must_use]
    pub const fn status_code(&self) -> &SqlState {
        &self.status_code
    }
}

impl fmt::Display for CustomPgDbError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Custom postgres error with status code {}",
            self.status_code.code()
        )
    }
}

impl std::error::Error for CustomPgDbError {}
