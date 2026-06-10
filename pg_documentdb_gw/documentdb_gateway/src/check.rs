/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway/src/check.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::expect_used,
    reason = "Main binary uses expect for initialization failures that should crash the process"
)]

use documentdb_gateway_core::{
    configuration::{DocumentDBSetupConfiguration, SetupConfiguration},
    postgres::{conn_mgmt, create_query_catalog},
};

/// Connectivity probe used by the post-install smoke test.
///
/// Opens connections through the configured `PostgreSQL` backend, runs the
/// same extension-backed startup validation as the service-start path, and
/// then explicitly fetches the installed `documentdb` extension version
/// so the success message reports something operators can verify against
/// their package set. Returns 0 on success, 1 on any failure (with a
/// human-readable message plus a hint on stderr).
pub fn run_check(setup_configuration: &DocumentDBSetupConfiguration) -> i32 {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime");

    let host = setup_configuration.postgres_host_name().to_owned();
    let port = setup_configuration.postgres_port();
    let database = setup_configuration.postgres_database().to_owned();
    let user = setup_configuration.postgres_data_user().to_owned();

    let result = runtime.block_on(async {
        // create_connection_pool_manager runs validate_startup_pools,
        // which executes an extension-backed query against both the
        // SystemRequests and PreAuthRequests pools. Any failure here
        // (PG unreachable, peer-auth ident map wrong, extension not
        // created in the target database) propagates through `?`.
        let pool = conn_mgmt::create_connection_pool_manager(
            create_query_catalog(),
            Box::new(setup_configuration.clone()),
        )
        .await?;

        // Pool validation already proved the connection works and the
        // extension is loaded. Run one more targeted query so we can
        // report the actual installed extension version — useful when
        // diagnosing version-skew issues between the gateway binary
        // and the extension package.
        let connection = pool.system_requests_connection().await?;
        let rows = connection
            .query(
                "SELECT extversion FROM pg_extension WHERE extname = 'documentdb'",
                &[],
                &[],
            )
            .await
            .map_err(|e| {
                documentdb_gateway_core::error::DocumentDBError::internal_error(format!(
                    "Failed to query pg_extension for 'documentdb': {e}"
                ))
            })?;

        let extension_version: Option<String> = rows
            .first()
            .and_then(|row| row.try_get::<_, Option<String>>(0).ok().flatten());

        Ok::<Option<String>, documentdb_gateway_core::error::DocumentDBError>(extension_version)
    });

    match result {
        Ok(Some(ext_version)) => {
            println!(
                "documentdb-gateway: check OK\n  \
                 backend:    postgresql://{user}@{host}:{port}/{database}\n  \
                 extension:  documentdb {ext_version}\n  \
                 binary:     documentdb-gateway {}",
                env!("CARGO_PKG_VERSION")
            );
            0
        }
        Ok(None) => {
            eprintln!(
                "documentdb-gateway: check FAILED\n  \
                 backend:    postgresql://{user}@{host}:{port}/{database}\n  \
                 reason:     pool validation succeeded but pg_extension reports no row for 'documentdb'.\n  \
                 hint:       run 'sudo -u postgres psql -d {database} -c \"CREATE EXTENSION documentdb CASCADE;\"' on the backend."
            );
            1
        }
        Err(e) => {
            eprintln!(
                "documentdb-gateway: check FAILED\n  \
                 backend:    postgresql://{user}@{host}:{port}/{database}\n  \
                 error:      {e}\n  \
                 hints:\n    \
                 - Is PostgreSQL running? (e.g. 'systemctl status postgresql' or 'pg_isready')\n    \
                 - Did documentdb-register-gateway / documentdb-setup finish writing pg_hba.conf?\n    \
                 - Is the extension created in the target database? ('CREATE EXTENSION documentdb CASCADE')\n    \
                 - Does the gateway have read access to DOCUMENTDB_PG_URL_FILE?"
            );
            1
        }
    }
}
