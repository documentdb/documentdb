// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/*-------------------------------------------------------------------------
 * documentdb_tests/tests/configuration_refresh_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Weak,
    },
    time::Duration,
};

use documentdb_gateway_core::{
    configuration::{
        ConfigurationRefreshObserver, DynamicConfiguration, PgConfiguration, SetupConfiguration,
    },
    postgres::{
        self,
        conn_mgmt::{ConnectionPool, PgPoolSettings, PoolManager},
    },
};
use documentdb_tests::test_setup::config;
use tokio::time::{sleep, timeout};
use uuid::Uuid;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[derive(Debug)]
struct Observer {
    configuration: Weak<PgConfiguration>,
    notifications: AtomicUsize,
    published_primary: AtomicUsize,
}

impl ConfigurationRefreshObserver for Observer {
    fn configuration_refreshed(&self) {
        if let Some(configuration) = self.configuration.upgrade() {
            self.published_primary.store(
                usize::from(configuration.get_bool("IsPrimary", false)),
                Ordering::Relaxed,
            );
            self.notifications.fetch_add(1, Ordering::Release);
        }
    }
}

struct Fixture {
    configuration: Arc<PgConfiguration>,
    observer: Arc<Observer>,
    host_file: PathBuf,
}

impl Fixture {
    async fn new(periodic: bool, topology_query: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let host_file = std::env::temp_dir().join(format!("configuration-{}.json", Uuid::new_v4()));
        std::fs::write(&host_file, r#"{"IsPrimary":"false"}"#)?;
        let mut setup = config::setup_configuration();
        setup.dynamic_configuration_file = host_file.to_string_lossy().into_owned();
        setup.dynamic_configuration_refresh_interval_secs = Some(if periodic { 1 } else { 3_600 });
        setup.host_configuration_watch_interval_ms = Some(if periodic { 3_600_000 } else { 10 });
        let mut catalog = postgres::create_query_catalog();
        "SELECT 'max_connections'::text, '16'::text".clone_into(&mut catalog.pg_settings);
        catalog.pg_file_settings.clear();
        catalog.extension_versions = topology_query.to_owned();
        let pool = |name| {
            ConnectionPool::new_with_user(
                &setup,
                &catalog,
                setup.postgres_system_user(),
                None,
                name,
                PgPoolSettings::system_pool_settings(2),
            )
        };
        let manager = Arc::new(PoolManager::new(
            catalog.clone(),
            Box::new(setup.clone()),
            pool("refresh-test")?,
            pool("refresh-auth-test")?,
        ));
        let configuration = PgConfiguration::new(&setup, manager, Vec::new()).await?;
        let observer = Arc::new(Observer {
            configuration: Arc::downgrade(&configuration),
            notifications: AtomicUsize::new(0),
            published_primary: AtomicUsize::new(0),
        });
        let erased: Arc<dyn ConfigurationRefreshObserver> = Arc::<Observer>::clone(&observer);
        configuration.set_refresh_observer(Arc::downgrade(&erased));
        Ok(Self {
            configuration,
            observer,
            host_file,
        })
    }

    async fn wait_for_notification(&self) -> TestResult {
        timeout(Duration::from_secs(5), async {
            while self.observer.notifications.load(Ordering::Acquire) == 0 {
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await?;
        Ok(())
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.host_file) {
            tracing::warn!("Could not remove test host configuration: {error}");
        }
    }
}

#[tokio::test]
async fn periodic_refresh_notifies_after_publication_without_retaining_the_owner() -> TestResult {
    let fixture = Fixture::new(true, "").await?;
    assert_eq!(fixture.observer.notifications.load(Ordering::Relaxed), 0);
    std::fs::write(&fixture.host_file, r#"{"IsPrimary":"true"}"#)?;
    fixture.wait_for_notification().await?;
    assert_eq!(
        fixture.observer.published_primary.load(Ordering::Relaxed),
        1
    );
    let owner = Arc::downgrade(&fixture.observer);
    let configuration = Arc::clone(&fixture.configuration);
    drop(fixture);
    assert!(owner.upgrade().is_none());
    configuration.refresh_configuration().await?;
    Ok(())
}

#[tokio::test]
async fn host_file_refresh_uses_the_same_publication_notification() -> TestResult {
    let fixture = Fixture::new(false, "").await?;
    sleep(Duration::from_millis(50)).await;
    let before = fixture.observer.notifications.load(Ordering::Acquire);
    std::fs::write(
        &fixture.host_file,
        r#"{"IsPrimary":"true","SendShutdownResponses":"false"}"#,
    )?;
    timeout(Duration::from_secs(5), async {
        while fixture.observer.notifications.load(Ordering::Acquire) == before {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await?;
    assert_eq!(
        fixture.observer.published_primary.load(Ordering::Relaxed),
        1
    );
    Ok(())
}

#[tokio::test]
async fn failed_refresh_neither_notifies_nor_publishes_freshness() -> TestResult {
    let fixture = Fixture::new(false, "SELECT * FROM refresh_observer_missing_relation").await?;
    let published_at = fixture.configuration.last_update_at();
    assert!(fixture.configuration.refresh_configuration().await.is_err());
    assert_eq!(fixture.configuration.last_update_at(), published_at);
    assert_eq!(fixture.observer.notifications.load(Ordering::Acquire), 0);
    Ok(())
}

#[tokio::test]
async fn explicit_refresh_notifies_only_the_current_live_observer() -> TestResult {
    let fixture = Fixture::new(false, "").await?;
    fixture.configuration.refresh_configuration().await?;
    assert_eq!(fixture.observer.notifications.load(Ordering::Acquire), 1);
    let replacement = Arc::new(Observer {
        configuration: Arc::downgrade(&fixture.configuration),
        notifications: AtomicUsize::new(0),
        published_primary: AtomicUsize::new(0),
    });
    let erased: Arc<dyn ConfigurationRefreshObserver> = Arc::<Observer>::clone(&replacement);
    fixture
        .configuration
        .set_refresh_observer(Arc::downgrade(&erased));
    fixture.configuration.refresh_configuration().await?;
    assert_eq!(replacement.notifications.load(Ordering::Acquire), 1);
    assert_eq!(fixture.observer.notifications.load(Ordering::Acquire), 1);
    let owner = Arc::downgrade(&replacement);
    drop(erased);
    drop(replacement);
    assert!(owner.upgrade().is_none());
    fixture.configuration.refresh_configuration().await?;
    assert_eq!(fixture.observer.notifications.load(Ordering::Acquire), 1);
    Ok(())
}
