/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/gateway.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use documentdb_gateway_core::{
    configuration::{DocumentDBSetupConfiguration, PgConfiguration, SetupConfiguration},
    error::Result,
    postgres::DocumentDBDataClient,
    run_gateway,
    service::TlsProvider,
    startup::get_service_context,
};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use crate::test_setup::postgres::get_pool_manager;

/// Starts the test gateway with the provided configuration, signalling
/// readiness via the given flag and notifier.
///
/// # Errors
///
/// Returns an error if TLS setup, configuration loading, or the gateway
/// runtime fails.
///
/// # Panics
///
/// Panics if the `tokio` runtime cannot be created.
#[tokio::main]
pub async fn run_test_gateway(
    setup_config: DocumentDBSetupConfiguration,
    ready_notify: &Arc<Notify>,
    ready_flag: &Arc<AtomicBool>,
) -> Result<()> {
    let tls_provider = TlsProvider::new(
        SetupConfiguration::certificate_options(&setup_config),
        None,
        None,
    )
    .await?;

    let connection_pool_manager = get_pool_manager();

    let dynamic_configuration = PgConfiguration::new(
        &setup_config,
        Arc::clone(&connection_pool_manager),
        vec!["documentdb.".to_owned()],
    )
    .await?;

    let service_context = get_service_context(
        Box::new(setup_config),
        dynamic_configuration,
        connection_pool_manager,
        tls_provider,
    );

    ready_flag.store(true, Ordering::SeqCst);
    ready_notify.notify_waiters();

    run_gateway::<DocumentDBDataClient>(service_context, None, CancellationToken::new()).await
}
