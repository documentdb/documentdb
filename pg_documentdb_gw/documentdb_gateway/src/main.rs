/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway/src/main.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::expect_used,
    reason = "Main binary uses expect for initialization failures that should crash the process"
)]
#![expect(
    clippy::unwrap_used,
    reason = "Main binary uses unwrap for failures that should crash the process"
)]

#[cfg(feature = "mimalloc")]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod bootstrap;
mod check;
mod cli;

use std::sync::Arc;

use documentdb_gateway_core::{
    configuration::{DocumentDBSetupConfiguration, PgConfiguration, SetupConfiguration},
    postgres::{conn_mgmt, create_query_catalog, DocumentDBDataClient},
    run_gateway,
    service::TlsProvider,
    shutdown_controller::SHUTDOWN_CONTROLLER,
    startup::{create_postgres_object, get_service_context},
    telemetry::{TelemetryConfig, TelemetryManager},
};
use tokio::signal;

fn main() {
    // Dispatch documentdb-gateway --help/--version/check subcommands; exits
    // if any matched. For `run [--config <path>]` returns Some(path) (path is
    // guaranteed to exist — cli validated). For the legacy invocation form
    // `documentdb-gateway <path>` also returns Some(path) with the same
    // must-exist guarantee. For the no-args form, returns None.
    let explicit_config = cli::dispatch_or_passthrough();

    let setup_configuration = bootstrap::with_bootstrap_tracing(|| {
        // Load configuration via the shared helper so the `run` daemon path uses
        // the same 3-tier resolution (explicit → packaged → dev → env-only) as
        // the `check` subcommand. When explicit_config is Some(path), the path
        // is guaranteed to exist; when None, the helper does the 3-tier fallback.
        let setup_configuration = bootstrap::load_configuration(explicit_config);
        tracing::info!("Starting server with configuration: {setup_configuration:?}");
        setup_configuration
    });

    // Create Tokio runtime with configured worker threads
    let async_runtime_worker_threads = setup_configuration.async_runtime_worker_threads();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(async_runtime_worker_threads)
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime");

    bootstrap::with_bootstrap_tracing(|| {
        tracing::info!("Created Tokio runtime with {async_runtime_worker_threads} worker threads");
    });

    // Run the async main logic
    runtime.block_on(start_gateway(setup_configuration));
}

async fn start_gateway(setup_configuration: DocumentDBSetupConfiguration) {
    // Initialize telemetry first so the OTLP tracer provider is available before the
    // `tracing` subscriber is constructed. Both providers are owned by the manager and
    // shut down before the runtime exits, ensuring batched data is flushed.
    let telemetry_config = TelemetryConfig::new(setup_configuration.telemetry_options());

    let telemetry_manager = if telemetry_config.any_signal_enabled() {
        match TelemetryManager::init_telemetry(&telemetry_config, None) {
            Ok(manager) => Some(manager),
            Err(e) => {
                eprintln!("Failed to initialize OpenTelemetry: {e}");
                None
            }
        }
    } else {
        None
    };

    bootstrap::init_tracing_with_telemetry(telemetry_manager.as_ref());

    tracing::info!(
        "Tracing subscriber installed (otel_traces_enabled={})",
        telemetry_manager
            .as_ref()
            .and_then(TelemetryManager::tracer_provider)
            .is_some()
    );

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

    let connection_pool_manager = create_postgres_object(
        || async {
            conn_mgmt::create_connection_pool_manager(
                create_query_catalog(),
                Box::new(setup_configuration.clone()),
            )
            .await
        },
        &setup_configuration,
    )
    .await;

    let dynamic_configuration = create_postgres_object(
        || async {
            PgConfiguration::new(
                &setup_configuration,
                Arc::clone(&connection_pool_manager),
                vec!["documentdb.".to_owned()],
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

    if let Some(manager) = telemetry_manager {
        if let Err(err) = manager.shutdown() {
            tracing::error!("Failed to shutdown telemetry manager: {err}");
        }
    }
}
