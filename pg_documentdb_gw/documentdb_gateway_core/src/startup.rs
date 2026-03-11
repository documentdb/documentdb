/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/startup.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use tokio::time::{Duration, Instant};

use crate::{
    auth::{
        oidc_provider::OidcProvider,
        provider::ProviderConfig,
        registry::AuthProviderRegistry,
        scram_provider::ScramProvider,
    },
    configuration::{DynamicConfiguration, SetupConfiguration},
    context::ServiceContext,
    error::Result,
    postgres::conn_mgmt::{self, PoolManager},
    service::TlsProvider,
};

pub async fn get_service_context(
    setup_configuration: Box<dyn SetupConfiguration>,
    dynamic_configuration: Arc<dyn DynamicConfiguration>,
    connection_pool_manager: Arc<PoolManager>,
    tls_provider: TlsProvider,
) -> ServiceContext {
    tracing::info!("Initial dynamic configuration: {dynamic_configuration:?}");

    let auth_provider_registry = init_auth_provider_registry().await;

    let service_context = ServiceContext::new(
        setup_configuration.clone(),
        Arc::clone(&dynamic_configuration),
        connection_pool_manager,
        tls_provider,
        Some(auth_provider_registry),
    );

    conn_mgmt::clean_unused_pools(service_context.clone());

    service_context
}

/// Build and initialize the auth provider registry with the default providers.
async fn init_auth_provider_registry() -> AuthProviderRegistry {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    if let Err(e) = registry.register(Box::new(ScramProvider::new()), &config).await {
        tracing::error!("Failed to register ScramProvider: {e}");
    }
    if let Err(e) = registry.register(Box::new(OidcProvider::new()), &config).await {
        tracing::error!("Failed to register OidcProvider: {e}");
    }

    registry
}

pub async fn create_postgres_object<T, F, Fut>(
    create_func: F,
    setup_configuration: &dyn SetupConfiguration,
) -> T
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let max_time = Duration::from_secs(setup_configuration.postgres_startup_wait_time_seconds());
    let wait_time = Duration::from_secs(10);
    let start = Instant::now();

    loop {
        match create_func().await {
            Ok(result) => {
                return result;
            }
            Err(e) => {
                if start.elapsed() < max_time {
                    tracing::warn!("Exception when creating postgres object {e:?}");
                    tokio::time::sleep(wait_time).await;
                    continue;
                } else {
                    panic!("Failed to create postgres object after {max_time:?}: {e}");
                }
            }
        }
    }
}
