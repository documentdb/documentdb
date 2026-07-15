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
    configuration::{DynamicConfiguration, SetupConfiguration},
    context::ServiceContext,
    error::Result,
    postgres::conn_mgmt::{self, PoolManager},
    service::TlsProvider,
    shutdown_controller::SHUTDOWN_CONTROLLER,
};

pub fn get_service_context(
    setup_configuration: Box<dyn SetupConfiguration>,
    dynamic_configuration: Arc<dyn DynamicConfiguration>,
    connection_pool_manager: Arc<PoolManager>,
    tls_provider: TlsProvider,
) -> ServiceContext {
    tracing::info!("Initial dynamic configuration: {dynamic_configuration:?}");

    let service_context = ServiceContext::new(
        setup_configuration,
        dynamic_configuration,
        connection_pool_manager,
        tls_provider,
    );

    conn_mgmt::clean_unused_pools(service_context.clone());

    service_context
}

/// # Panics
///
/// Panics if `create_func` keeps failing after the configured startup wait window.
pub async fn create_postgres_object<T, F, Fut>(
    create_func: F,
    setup_configuration: &dyn SetupConfiguration,
) -> T
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    create_postgres_object_with_retry_interval(
        create_func,
        setup_configuration,
        Duration::from_secs(10),
    )
    .await
}

async fn create_postgres_object_with_retry_interval<T, F, Fut>(
    create_func: F,
    setup_configuration: &dyn SetupConfiguration,
    wait_time: Duration,
) -> T
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let max_time = Duration::from_secs(setup_configuration.postgres_startup_wait_time_seconds());
    let start = Instant::now();
    let shutdown_token = SHUTDOWN_CONTROLLER.token();

    loop {
        match create_func().await {
            Ok(result) => return result,
            Err(error) if start.elapsed() < max_time => {
                tracing::warn!(
                    "Exception when creating postgres object {error:?}. Retrying in \
                     {wait_time:?}."
                );
                // Race the retry backoff against the shutdown signal so a
                // Ctrl+C received while we're stuck retrying triggers an
                // immediate exit instead of waiting for the next attempt.
                tokio::select! {
                    () = tokio::time::sleep(wait_time) => {}
                    () = shutdown_token.cancelled() => {
                        tracing::info!(
                            "Shutdown signal received during postgres startup. \
                             Aborting immediately."
                        );
                        std::process::exit(0);
                    }
                }
            }
            Err(error) => {
                panic!("Failed to create postgres object after {max_time:?}: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::atomic::{AtomicUsize, Ordering};

    use crate::{configuration::DocumentDBSetupConfiguration, error::DocumentDBError};

    #[tokio::test]
    async fn create_postgres_object_retries_until_success() {
        let setup_configuration = DocumentDBSetupConfiguration {
            postgres_startup_wait_time_seconds: Some(1),
            ..Default::default()
        };
        let attempts = Arc::new(AtomicUsize::new(0));

        let result = create_postgres_object_with_retry_interval(
            || {
                let attempts = Arc::clone(&attempts);
                async move {
                    let attempt = attempts.fetch_add(1, Ordering::Relaxed);

                    if attempt < 2 {
                        Err(DocumentDBError::internal_error(
                            "temporary startup failure".to_owned(),
                        ))
                    } else {
                        Ok(42)
                    }
                }
            },
            &setup_configuration,
            Duration::from_millis(1),
        )
        .await;

        assert_eq!(42, result);
        assert_eq!(3, attempts.load(Ordering::Relaxed));
    }

    #[tokio::test]
    #[should_panic(expected = "Failed to create postgres object after 0ns")]
    async fn create_postgres_object_panics_after_timeout() {
        let setup_configuration = DocumentDBSetupConfiguration {
            postgres_startup_wait_time_seconds: Some(0),
            ..Default::default()
        };

        create_postgres_object_with_retry_interval(
            || async {
                Err::<(), _>(DocumentDBError::internal_error(
                    "permanent startup failure".to_owned(),
                ))
            },
            &setup_configuration,
            Duration::from_millis(1),
        )
        .await;
    }
}
