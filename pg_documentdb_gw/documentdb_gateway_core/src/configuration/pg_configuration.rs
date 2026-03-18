/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/pg_configuration.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{collections::HashMap, path::Path, sync::Arc, time::SystemTime};

use arc_swap::ArcSwap;
use bson::{rawbson, RawBson};
use serde::Deserialize;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};

use crate::{
    configuration::{dynamic::POSTGRES_RECOVERY_KEY, DynamicConfiguration, SetupConfiguration},
    error::{DocumentDBError, Result},
    postgres::{conn_mgmt::PoolManager, PgDocument},
    requests::request_tracker::RequestTracker,
};

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct HostConfig {
    #[serde(default)]
    is_primary: String,
    #[serde(default)]
    send_shutdown_responses: String,
}

/// Inner struct that holds the dependencies needed for loading configurations.
#[derive(Debug, Clone)]
struct PgConfigurationInner {
    dynamic_config_path: String,
    settings_prefixes: Vec<String>,
    pool_manager: Arc<PoolManager>,
}

impl PgConfigurationInner {
    /// Loads configurations from the database and config file using the provided connection.
    async fn load_configurations(&self) -> Result<HashMap<String, String>> {
        let mut configs = HashMap::new();

        match Self::load_host_config(&self.dynamic_config_path).await {
            Ok(host_config) => {
                configs.insert(
                    "IsPrimary".to_owned(),
                    host_config.is_primary.to_lowercase(),
                );
                configs.insert(
                    "SendShutdownResponses".to_owned(),
                    host_config.send_shutdown_responses.to_lowercase(),
                );
            }
            Err(e) => tracing::warn!("Host Config file not able to be loaded: {e}"),
        }

        let request_tracker = RequestTracker::new();
        let pg_config_rows = self
            .pool_manager
            .system_requests_connection()
            .await?
            .query(
                self.pool_manager.query_catalog().pg_settings(),
                &[],
                &[],
                None,
                &request_tracker,
            )
            .await?;

        for pg_config in pg_config_rows {
            let mut key = pg_config.get::<_, String>(0);

            for settings_prefix in &self.settings_prefixes {
                if key.starts_with(settings_prefix) {
                    key = key[settings_prefix.len()..].to_string();
                    break;
                }
            }

            let mut value: String = pg_config.get(1);
            if value == "on" {
                "true".clone_into(&mut value);
            } else if value == "off" {
                "false".clone_into(&mut value);
            }
            configs.insert(key.clone(), value);
        }

        let pg_is_in_recovery_row = self
            .pool_manager
            .system_requests_connection()
            .await?
            .query(
                self.pool_manager.query_catalog().pg_is_in_recovery(),
                &[],
                &[],
                None,
                &request_tracker,
            )
            .await?;

        let in_recovery: bool = pg_is_in_recovery_row.first().is_some_and(|row| row.get(0));
        configs.insert(POSTGRES_RECOVERY_KEY.to_owned(), in_recovery.to_string());

        tracing::info!("Dynamic configurations loaded: {configs:?}");
        Ok(configs)
    }

    async fn load_host_config(dynamic_config_path: &str) -> Result<HostConfig> {
        let config: HostConfig = serde_json::from_str(
            &tokio::fs::read_to_string(dynamic_config_path).await?,
        )
        .map_err(|e| DocumentDBError::internal_error(format!("Failed to read config file: {e}")))?;
        Ok(config)
    }
}

#[derive(Debug)]
pub struct PgConfiguration {
    inner: PgConfigurationInner,
    values: ArcSwap<HashMap<String, String>>,
    last_update_at: ArcSwap<Instant>,
    topology_bson: ArcSwap<RawBson>,
    refresh_task: Option<JoinHandle<()>>,
    watch_task: Option<JoinHandle<()>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WatchedFileState {
    exists: bool,
    modified_at: Option<SystemTime>,
    len: Option<u64>,
}

impl PgConfiguration {
    fn start_dynamic_configuration_refresh_thread(
        configuration: Arc<Self>,
        refresh_interval: u32,
    ) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut interval =
                tokio::time::interval(Duration::from_secs(u64::from(refresh_interval)));
            interval.tick().await;

            loop {
                interval.tick().await;

                Self::reload_configuration(&configuration).await;
            }
        })
    }

    async fn reload_configuration(configuration: &Self) {
        if let Err(e) = configuration.refresh_configuration().await {
            tracing::error!("Config reload failed! {e}");
        }
    }

    async fn get_file_state(path: &Path) -> WatchedFileState {
        match tokio::fs::metadata(path).await {
            Ok(metadata) => WatchedFileState {
                exists: true,
                modified_at: metadata.modified().ok(),
                len: Some(metadata.len()),
            },
            Err(_) => WatchedFileState {
                exists: false,
                modified_at: None,
                len: None,
            },
        }
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn new(
        setup_configuration: &dyn SetupConfiguration,
        pool_manager: Arc<PoolManager>,
        settings_prefixes: Vec<String>,
    ) -> Result<Arc<Self>> {
        let inner = PgConfigurationInner {
            dynamic_config_path: setup_configuration.dynamic_configuration_file(),
            settings_prefixes,
            pool_manager,
        };

        let values = ArcSwap::from_pointee(inner.load_configurations().await?);
        let last_update_at = ArcSwap::from_pointee(Instant::now());
        let topology_bson = ArcSwap::from_pointee(Self::load_topology(&inner.pool_manager).await);

        let mut configuration = Arc::new(Self {
            inner,
            values,
            last_update_at,
            topology_bson,
            refresh_task: None,
            watch_task: None,
        });

        let refresh_interval = setup_configuration.dynamic_configuration_refresh_interval_secs();
        let watch_interval_ms = setup_configuration.host_configuration_watch_interval_ms();

        let refresh_task = Self::start_dynamic_configuration_refresh_thread(
            Arc::clone(&configuration),
            refresh_interval,
        );
        let watch_task = Self::start_config_watcher(Arc::clone(&configuration), watch_interval_ms);

        if let Some(config) = Arc::get_mut(&mut configuration) {
            config.refresh_task = Some(refresh_task);
            config.watch_task = Some(watch_task);
        }

        Ok(configuration)
    }

    pub fn last_update_at(&self) -> Instant {
        *self.last_update_at.load_full()
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn refresh_configuration(&self) -> Result<()> {
        let new_config = match self.inner.load_configurations().await {
            Ok(config) => config,
            Err(e) => {
                tracing::error!("Failed to reload configuration: {e}");
                return Err(e);
            }
        };

        self.values.store(Arc::new(new_config));
        self.topology_bson.store(Arc::new(
            Self::load_topology(&self.inner.pool_manager).await,
        ));
        self.last_update_at.store(Arc::new(Instant::now()));

        Ok(())
    }

    fn start_config_watcher(configuration: Arc<Self>, watch_interval_ms: u64) -> JoinHandle<()> {
        let dynamic_config_path = configuration.inner.dynamic_config_path.clone();
        let file_path = Path::new(&dynamic_config_path).to_path_buf();
        let poll_interval = Duration::from_millis(watch_interval_ms);

        tracing::info!(
            "Config file polling watcher enabled on: {} ({}ms)",
            dynamic_config_path,
            poll_interval.as_millis()
        );

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(poll_interval);
            let mut previous_state = Self::get_file_state(&file_path).await;

            loop {
                interval.tick().await;
                let current_state = Self::get_file_state(&file_path).await;

                if current_state != previous_state {
                    tracing::info!(
                        "Config file state changed for {}. Reloading dynamic configuration.",
                        file_path.display()
                    );
                    Self::reload_configuration(&configuration).await;
                    previous_state = current_state;
                }
            }
        })
    }

    async fn load_topology(pool_manager: &PoolManager) -> RawBson {
        let extension_versions_query = pool_manager.query_catalog().extension_versions();
        if extension_versions_query.is_empty() {
            return rawbson!({});
        }

        let results = match async {
            let conn = pool_manager.system_requests_connection().await?;
            conn.query(
                extension_versions_query,
                &[],
                &[],
                None,
                &RequestTracker::new(),
            )
            .await
        }
        .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::error!("Failed to load topology versions: {e}");
                return rawbson!({});
            }
        };

        let Some(result) = results.first() else {
            tracing::error!("No results returned for extension versions query");
            return rawbson!({});
        };

        let doc: std::result::Result<PgDocument, _> = result.try_get(0);
        match doc {
            Ok(doc) => {
                tracing::info!("Topology acquired: {doc:?}");
                match doc.0.get("internal") {
                    Ok(Some(value)) => rawbson!({
                        "documentdb_versions": value.to_raw_bson()
                    }),
                    _ => rawbson!({}),
                }
            }
            Err(e) => {
                tracing::error!("Failed to parse extension versions: {e}");
                rawbson!({})
            }
        }
    }
}

impl DynamicConfiguration for PgConfiguration {
    fn get_str(&self, key: &str) -> Option<String> {
        self.values.load_full().get(key).cloned()
    }
    fn get_bool(&self, key: &str, default: bool) -> bool {
        self.values
            .load_full()
            .get(key)
            .map_or(default, |v| v.parse::<bool>().unwrap_or(default))
    }
    fn get_i32(&self, key: &str, default: i32) -> i32 {
        self.values
            .load_full()
            .get(key)
            .map_or(default, |v| v.parse::<i32>().unwrap_or(default))
    }
    fn get_u64(&self, key: &str, default: u64) -> u64 {
        self.values
            .load_full()
            .get(key)
            .map_or(default, |v| v.parse::<u64>().unwrap_or(default))
    }
    fn equals_value(&self, key: &str, value: &str) -> bool {
        self.values.load_full().get(key).is_some_and(|v| v == value)
    }

    fn topology(&self) -> RawBson {
        self.topology_bson.load_full().as_ref().clone()
    }

    fn enable_developer_explain(&self) -> bool {
        self.get_bool("enableDeveloperExplain", false)
    }

    fn max_connections(&self) -> usize {
        let max_connections = self.get_i32("max_connections", -1);
        match max_connections {
            n if n < 0 => {
                // theoretically we can't end up here, since Postgres always provide values
                tracing::error!("GUC max_connections is not setup correctly");
                25usize
            }
            n => usize::try_from(n).unwrap_or(25),
        }
    }

    fn allow_transaction_snapshot(&self) -> bool {
        self.get_bool("mongoAllowTransactionSnapshot", false)
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl Drop for PgConfiguration {
    fn drop(&mut self) {
        if let Some(refresh_task) = &self.refresh_task {
            refresh_task.abort();
        }

        if let Some(watch_task) = &self.watch_task {
            watch_task.abort();
        }
    }
}
