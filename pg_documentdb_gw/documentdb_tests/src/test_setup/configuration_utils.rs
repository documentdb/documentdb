/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/configuration_utils.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_gateway_core::error::{DocumentDBError, Result};

use crate::test_setup::postgres;

/// Applies a GUC value via `ALTER SYSTEM SET` and reloads the configuration.
///
/// # Errors
///
/// Returns an error if the SQL statements fail.
pub async fn apply_guc(key: &str, value: &str) -> Result<()> {
    let pool_manager = postgres::get_pool_manager();
    let connection = pool_manager.system_requests_connection().await?;
    connection
        .batch_execute(&format!("ALTER SYSTEM SET {key} = \"{value}\""))
        .await?;
    connection.batch_execute("SELECT pg_reload_conf()").await?;
    Ok(())
}

/// RAII guard that reverts a GUC to its previous value on drop.
#[derive(Debug)]
pub struct GucGuard {
    key: String,
    old_value: String,
}

impl Drop for GucGuard {
    fn drop(&mut self) {
        let key = self.key.clone();
        let old_value = self.old_value.clone();

        tokio::spawn(async move {
            if let Err(e) = apply_guc(&key, &old_value).await {
                tracing::warn!("Failed to revert GUC {key} to {old_value}: {e}");
            }
        });
    }
}

/// Sets a GUC parameter and returns a guard that reverts it on drop.
///
/// # Errors
///
/// Returns an error if the current value cannot be read or if applying
/// the new value fails.
pub async fn set_guc(key: &str, value: &str) -> Result<GucGuard> {
    let pool_manager = postgres::get_pool_manager();

    let old_value: String = {
        let connection = pool_manager.system_requests_connection().await?;

        let results = connection.query(&format!("SHOW {key}"), &[], &[]).await?;

        let result = results
            .first()
            .ok_or(DocumentDBError::internal_error(format!(
                "Didn't get any results for SHOW {key}"
            )))?;

        result.try_get(0)?
    };

    apply_guc(key, value).await?;

    Ok(GucGuard {
        key: key.to_owned(),
        old_value,
    })
}
