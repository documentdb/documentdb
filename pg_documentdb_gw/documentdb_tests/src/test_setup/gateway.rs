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
    postgres::DocumentDBDataClient,
    run_gateway,
    service::TlsProvider,
    startup::get_service_context,
};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use crate::test_setup::postgres::get_pool_manager;

#[tokio::main]
pub async fn run_test_gateway(
    setup_config: DocumentDBSetupConfiguration,
    ready_notify: &Arc<Notify>,
    ready_flag: &Arc<AtomicBool>,
) {
    let tls_provider = TlsProvider::new(
        SetupConfiguration::certificate_options(&setup_config),
        None,
        None,
    )
    .await
    .expect("Failed to create TLS provider.");

    let connection_pool_manager = get_pool_manager();

    let dynamic_configuration = PgConfiguration::new(
        &setup_config,
        Arc::clone(&connection_pool_manager),
        vec!["documentdb.".to_string()],
    )
    .await
    .unwrap();

    let service_context = get_service_context(
        Box::new(setup_config),
        dynamic_configuration,
        connection_pool_manager,
        tls_provider,
    );

    ready_flag.store(true, Ordering::SeqCst);
    ready_notify.notify_waiters();

    run_gateway::<DocumentDBDataClient>(service_context, None, CancellationToken::new())
        .await
        .unwrap();
}
