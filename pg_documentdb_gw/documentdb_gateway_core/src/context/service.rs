/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/service.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use crate::{
    configuration::{DynamicConfiguration, SetupConfiguration},
    context::{CursorStore, TransactionStore},
    postgres::{conn_mgmt::PoolManager, QueryCatalog},
    service::TlsProvider,
};

#[derive(Debug)]
pub struct ServiceContextInner {
    pub setup_configuration: Box<dyn SetupConfiguration>,
    pub dynamic_configuration: Arc<dyn DynamicConfiguration>,
    pub connection_pool_manager: Arc<PoolManager>,
    pub cursor_store: CursorStore,
    pub transaction_store: TransactionStore,
    pub tls_provider: TlsProvider,
}

#[derive(Debug, Clone)]

pub struct ServiceContext(Arc<ServiceContextInner>);

impl ServiceContext {
    pub fn new(
        setup_configuration: Box<dyn SetupConfiguration>,
        dynamic_configuration: Arc<dyn DynamicConfiguration>,
        connection_pool_manager: Arc<PoolManager>,
        tls_provider: TlsProvider,
    ) -> Self {
        let timeout_secs = setup_configuration.transaction_timeout_secs();
        let cursor_store = CursorStore::new(Arc::clone(&dynamic_configuration), true);

        let inner = ServiceContextInner {
            setup_configuration,
            dynamic_configuration,
            connection_pool_manager,
            cursor_store,
            transaction_store: TransactionStore::new(Duration::from_secs(timeout_secs)),
            tls_provider,
        };
        Self(Arc::new(inner))
    }

    #[must_use]
    pub fn cursor_store(&self) -> &CursorStore {
        &self.0.cursor_store
    }

    #[must_use]
    pub fn setup_configuration(&self) -> &dyn SetupConfiguration {
        self.0.setup_configuration.as_ref()
    }

    #[must_use]
    pub fn dynamic_configuration(&self) -> Arc<dyn DynamicConfiguration> {
        Arc::clone(&self.0.dynamic_configuration)
    }

    #[must_use]
    pub fn transaction_store(&self) -> &TransactionStore {
        &self.0.transaction_store
    }

    #[must_use]
    pub fn query_catalog(&self) -> &QueryCatalog {
        self.0.connection_pool_manager.query_catalog()
    }

    #[must_use]
    pub fn tls_provider(&self) -> &TlsProvider {
        &self.0.tls_provider
    }

    #[must_use]
    pub fn connection_pool_manager(&self) -> &PoolManager {
        &self.0.connection_pool_manager
    }
}
