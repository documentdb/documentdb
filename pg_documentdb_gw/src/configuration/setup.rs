/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/configuration/setup.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{fs::File, path::Path};

use serde::Deserialize;

use crate::{
    configuration::{CertificateOptions, SetupConfiguration},
    error::{DocumentDBError, Result},
};

// Configurations which are populated statically on process start
#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct DocumentDBSetupConfiguration {
    pub application_name: Option<String>,
    pub node_host_name: String,
    pub blocked_role_prefixes: Vec<String>,

    // Gateway listener configuration
    pub use_local_host: Option<bool>,
    pub gateway_listen_port: Option<u16>,
    pub enforce_tls: Option<bool>,

    // Postgres configuration
    pub postgres_system_user: Option<String>,
    pub postgres_host_name: Option<String>,
    pub postgres_port: Option<u16>,
    pub postgres_database: Option<String>,

    #[serde(default)]
    pub allow_transaction_snapshot: Option<bool>,
    pub transaction_timeout_secs: Option<u64>,
    pub certificate_options: CertificateOptions,

    #[serde(default)]
    pub dynamic_configuration_file: String,
    pub dynamic_configuration_refresh_interval_secs: Option<u32>,
    pub postgres_command_timeout_secs: Option<u64>,
    pub postgres_startup_wait_time_seconds: Option<u64>,
    pub postgres_idle_connection_timeout_minutes: Option<u64>,

    // Runtime configuration
    pub async_runtime_worker_threads: Option<usize>,

    // Unix domain socket configuration
    // If specified with a non-empty path, Unix socket is enabled at that path.
    // If not specified (None), Unix socket is disabled.
    pub unix_socket_path: Option<String>,

    // Unix socket file permissions (octal format string, e.g., "0660" for owner+group read/write)
    // If not specified, defaults to 0o660
    pub unix_socket_file_permissions: Option<String>,
}

impl DocumentDBSetupConfiguration {
    pub fn new(config_path: &Path) -> Result<Self> {
        let config_file = File::open(config_path)?;
        let config: Self = serde_json::from_reader(config_file).map_err(|e| {
            DocumentDBError::internal_error(format!("Failed to parse configuration file: {e}"))
        })?;

        // Validate Unix socket path if provided
        if let Some(path) = &config.unix_socket_path {
            if path.trim().is_empty() {
                return Err(DocumentDBError::internal_error(
                    "UnixSocketPath cannot be empty. Either provide a valid path or omit the field to disable Unix sockets.".to_string()
                ));
            }
        }

        // Validate Unix socket permissions if provided
        if let Some(perm_str) = &config.unix_socket_file_permissions {
            if u32::from_str_radix(perm_str, 8).is_err() {
                return Err(DocumentDBError::internal_error(
                    format!("Invalid UnixSocketFilePermissions '{perm_str}'. Expected octal format like '0600', '0644'")
                ));
            }
        }

        Ok(config)
    }
}

impl SetupConfiguration for DocumentDBSetupConfiguration {
    // Needed to downcast to concrete type
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn postgres_host_name(&self) -> &str {
        self.postgres_host_name.as_deref().unwrap_or("localhost")
    }

    fn postgres_port(&self) -> u16 {
        self.postgres_port.unwrap_or(9712)
    }

    fn postgres_database(&self) -> &str {
        self.postgres_database.as_deref().unwrap_or("postgres")
    }

    fn postgres_system_user(&self) -> String {
        self.postgres_system_user
            .clone()
            .unwrap_or(whoami::username())
    }

    fn dynamic_configuration_file(&self) -> String {
        self.dynamic_configuration_file.clone()
    }

    fn dynamic_configuration_refresh_interval_secs(&self) -> u32 {
        self.dynamic_configuration_refresh_interval_secs
            .unwrap_or(60 * 5)
    }

    fn transaction_timeout_secs(&self) -> u64 {
        self.transaction_timeout_secs.unwrap_or(30)
    }

    fn use_local_host(&self) -> bool {
        self.use_local_host.unwrap_or(false)
    }

    fn gateway_listen_port(&self) -> u16 {
        self.gateway_listen_port.unwrap_or(10260)
    }

    fn blocked_role_prefixes(&self) -> &[String] {
        &self.blocked_role_prefixes
    }

    fn postgres_command_timeout_secs(&self) -> u64 {
        self.postgres_command_timeout_secs.unwrap_or(120)
    }

    fn certificate_options(&self) -> &CertificateOptions {
        &self.certificate_options
    }

    fn node_host_name(&self) -> &str {
        &self.node_host_name
    }

    fn application_name(&self) -> &str {
        self.application_name
            .as_deref()
            .unwrap_or("DocumentDBGateway")
    }

    fn postgres_startup_wait_time_seconds(&self) -> u64 {
        self.postgres_startup_wait_time_seconds.unwrap_or(60)
    }

    fn async_runtime_worker_threads(&self) -> usize {
        self.async_runtime_worker_threads.unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(|p| p.get())
                .unwrap_or(1)
        })
    }

    fn unix_socket_path(&self) -> Option<&str> {
        self.unix_socket_path.as_deref()
    }

    fn postgres_idle_connection_timeout_minutes(&self) -> u64 {
        self.postgres_idle_connection_timeout_minutes.unwrap_or(5)
    }

    fn enforce_tls(&self) -> bool {
        self.enforce_tls.unwrap_or(true)
    }

    fn unix_socket_file_permissions(&self) -> u32 {
        match &self.unix_socket_file_permissions {
            None => 0o660, // Default when not provided
            Some(perm_str) => u32::from_str_radix(perm_str, 8).unwrap(),
        }
    }
}
