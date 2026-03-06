/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/initialize.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Once, OnceLock,
    },
    thread,
};

use documentdb_gateway_core::configuration::DocumentDBSetupConfiguration;
use mongodb::{error::Error, Client, Database};
use tokio::sync::{Notify, OnceCell};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::test_setup::{
    clients::{get_client, get_client_unix_socket, setup_db, TEST_PASSWORD, TEST_USERNAME},
    config::{setup_configuration, setup_configuration_with_unix_socket_custom},
    gateway::run_test_gateway,
    postgres,
};

static TEST_SETUP: Once = Once::new();
static TEST_ASYNC_SETUP: OnceCell<()> = OnceCell::const_new();
static INITIALIZE_GATEWAY: Once = Once::new();

static GATEWAY_READY_NOTIFY: OnceLock<Arc<Notify>> = OnceLock::new();
static GATEWAY_READY_FLAG: OnceLock<Arc<AtomicBool>> = OnceLock::new();

fn test_init_once_sync() {
    TEST_SETUP.call_once(|| {
        tracing_subscriber::registry()
            .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug")))
            .with(tracing_subscriber::fmt::layer())
            .init();
    });
}

async fn test_init_once_async() {
    TEST_ASYNC_SETUP
        .get_or_init(|| async {
            // Create test user for authentication tests
            postgres::create_user(TEST_USERNAME, TEST_PASSWORD)
                .await
                .unwrap();
        })
        .await;
}

// Starts the server and returns an authenticated client
async fn initialize_full(setup_config: DocumentDBSetupConfiguration) {
    test_init_once_sync();
    test_init_once_async().await;

    let ready_notify = Arc::clone(GATEWAY_READY_NOTIFY.get_or_init(|| Arc::new(Notify::new())));
    let ready_flag =
        Arc::clone(GATEWAY_READY_FLAG.get_or_init(|| Arc::new(AtomicBool::new(false))));

    INITIALIZE_GATEWAY.call_once(|| {
        let ready_notify = Arc::clone(&ready_notify);
        let ready_flag = Arc::clone(&ready_flag);

        thread::spawn(move || {
            run_test_gateway(setup_config, &ready_notify, &ready_flag);
        });
    });

    while !ready_flag.load(Ordering::SeqCst) {
        ready_notify.notified().await;
    }
}

pub async fn initialize_with_config(config: DocumentDBSetupConfiguration) -> Client {
    initialize_full(config).await;
    get_client()
}

pub async fn initialize_with_config_and_unix(path: Option<String>) -> (Client, Option<Client>) {
    let config = setup_configuration_with_unix_socket_custom(path.clone(), None);
    initialize_full(config).await;

    let tcp_client = get_client();
    let unix_client = path.map(|socket_path| get_client_unix_socket(&socket_path));

    (tcp_client, unix_client)
}

pub async fn initialize() -> Client {
    initialize_full(setup_configuration()).await;
    get_client()
}

// Initialize the server and also clear a database for use
pub async fn initialize_with_db(db: &str) -> Result<Database, Error> {
    let client = initialize().await;

    setup_db(&client, db).await
}
