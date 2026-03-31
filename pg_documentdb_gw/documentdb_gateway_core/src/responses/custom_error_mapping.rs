/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/custom_error_mapping.rs
 *
 *-------------------------------------------------------------------------
 */
use std::fmt::Debug;

use tokio_postgres::error::SqlState;

use crate::responses::pg::PostgresErrorMappedResult;

/// Trait allowing consumers of the documentdb gateway to provide optional custom postgres error mapping.
///
/// This runs before the default/generic error mapping logic in `pg.rs`.
/// If the `map_postgres_error` method returns `None`, the default/generic mapping logic `map_pg_error_generic` in `pg.rs` is applied.
///
/// Only errors which are realted to custom documentdb extension implementations should be mapped here.
/// Otherwise, errors which are related to open sourced documentdb extension functionality should be mapped in `map_pg_error_generic` in `pg.rs`.
pub trait CustomPostgresErrorMapper: Send + Sync + Debug {
    fn map_postgres_error<'a>(
        &self,
        sql_state: &'a SqlState,
        msg: &'a str,
        activity_id: &str,
    ) -> Option<PostgresErrorMappedResult<'a>>;
}
