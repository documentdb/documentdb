/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/main.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{env, path::PathBuf, sync::Arc};

use documentdb_gateway::{
    configuration::{DocumentDBSetupConfiguration, PgConfiguration, SetupConfiguration},
    postgres::{
        conn_mgmt::create_connection_pool_manager, create_query_catalog, DocumentDBDataClient,
    },
    run_gateway,
    service::TlsProvider,
    shutdown_controller::SHUTDOWN_CONTROLLER,
    startup::{create_postgres_object, get_service_context},
};
use tokio::signal;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

fn main() {
    // Takes the configuration file as an argument
    let cfg_file = if let Some(arg1) = env::args().nth(1) {
        PathBuf::from(arg1)
    } else {
        // Defaults to the source directory for local runs
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("SetupConfiguration.json")
    };

    // Load configuration
    let setup_configuration =
        DocumentDBSetupConfiguration::new(&cfg_file).expect("Failed to load configuration.");

    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with(tracing_subscriber::fmt::layer())
        .init();

    tracing::info!("Starting server with configuration: {setup_configuration:?}");

    // Create Tokio runtime with configured worker threads
    let async_runtime_worker_threads = setup_configuration.async_runtime_worker_threads();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(async_runtime_worker_threads)
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime");

    tracing::info!("Created Tokio runtime with {async_runtime_worker_threads} worker threads");

    // Run the async main logic
    runtime.block_on(start_gateway(setup_configuration));
}

async fn start_gateway(setup_configuration: DocumentDBSetupConfiguration) {
    let shutdown_token = SHUTDOWN_CONTROLLER.token();

    tokio::spawn(async move {
        signal::ctrl_c().await.expect("Failed to listen for Ctrl+C");
        tracing::info!("Ctrl+C received. Shutting down Rust gateway.");
        SHUTDOWN_CONTROLLER.shutdown();
    });

    let tls_provider = TlsProvider::new(
        SetupConfiguration::certificate_options(&setup_configuration),
        None,
        None,
    )
    .await
    .expect("Failed to create TLS provider.");

    tracing::info!("TLS provider initialized successfully.");

    let connection_pool_manager = create_connection_pool_manager(
        create_query_catalog(),
        Box::new(setup_configuration.clone()),
    )
    .await;

    let dynamic_configuration = create_postgres_object(
        || async {
            PgConfiguration::new(
                &setup_configuration,
                Arc::clone(&connection_pool_manager),
                vec!["documentdb.".to_string()],
            )
            .await
        },
        &setup_configuration,
    )
    .await;

    let service_context = get_service_context(
        Box::new(setup_configuration),
        dynamic_configuration,
        connection_pool_manager,
        tls_provider,
    );

    run_gateway::<DocumentDBDataClient>(service_context, None, shutdown_token)
        .await
        .unwrap();
}
