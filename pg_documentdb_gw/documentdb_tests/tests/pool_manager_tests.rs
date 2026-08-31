/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/pool_manager_tests.rs
 *
 * Integration tests for `PoolManager` pool retention against a reachable local
 * PostgreSQL instance: which pools a disposal sweep keeps, and which it
 * disposes.
 *
 *-------------------------------------------------------------------------
 */
use std::time::Duration;

use documentdb_gateway_core::configuration::SetupConfiguration;
use documentdb_tests::test_setup::{
    config::setup_configuration,
    pools::{build_shared_pool_manager, TestConfiguration},
};
use tokio::time::sleep;

/// Retention the sweeps under test are given. Long enough that a pool used
/// immediately before a sweep is unambiguously inside the window, short enough
/// to keep the tests quick.
const RETENTION: Duration = Duration::from_millis(500);
/// Idle time applied to a pool the sweep is expected to dispose.
const BEYOND_RETENTION: Duration = Duration::from_millis(750);

/// The reported symptom was pools being disposed while they were serving
/// requests. Both directions belong in one lifecycle: recorded activity has to
/// hold a pool inside the retention window, and it has to stop holding it once
/// the pool goes idle. A `last_used` recorded in the wrong domain fails the
/// second half — it pins the pool outside the window's reach entirely, so the
/// pool is never disposed no matter how long it sits unused.
#[tokio::test]
async fn sweep_keeps_pool_in_use_then_disposes_it_once_idle() {
    let dynamic_configuration = TestConfiguration::default();
    let setup_config = setup_configuration();
    let pool_manager = build_shared_pool_manager(&setup_config);
    // The pool opens a real backend connection, so it borrows the user the test
    // PostgreSQL instance already accepts.
    let user = setup_config.postgres_system_user().to_owned();

    pool_manager
        .allocate_data_pool(&user, "", &dynamic_configuration)
        .unwrap();
    let pool = pool_manager
        .get_data_pool(&user, &dynamic_configuration)
        .unwrap();
    let connection = pool
        .acquire_connection()
        .await
        .expect("pool should serve a backend connection");
    drop(connection);

    pool_manager.clean_unused_pools(RETENTION);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_ok(),
        "a pool used inside the retention window must survive the sweep"
    );

    sleep(BEYOND_RETENTION).await;
    pool_manager.clean_unused_pools(RETENTION);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_err(),
        "a pool idle beyond the retention window must be disposed"
    );
}

/// The literal reported symptom: a pool disposed while it was serving a
/// request. Zero retention removes `last_used` from the question entirely, so
/// this pins the checked-out interlock on its own — and the second half proves
/// the interlock releases once the connection goes back.
#[tokio::test]
async fn sweep_spares_a_pool_with_a_connection_checked_out() {
    let dynamic_configuration = TestConfiguration::default();
    let setup_config = setup_configuration();
    let pool_manager = build_shared_pool_manager(&setup_config);
    let user = setup_config.postgres_system_user().to_owned();

    pool_manager
        .allocate_data_pool(&user, "", &dynamic_configuration)
        .unwrap();
    let pool = pool_manager
        .get_data_pool(&user, &dynamic_configuration)
        .unwrap();
    let connection = pool
        .acquire_connection()
        .await
        .expect("pool should serve a backend connection");

    pool_manager.clean_unused_pools(Duration::ZERO);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_ok(),
        "a pool with a connection checked out must survive the sweep"
    );

    drop(connection);
    pool_manager.clean_unused_pools(Duration::ZERO);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_err(),
        "a pool must become disposable once its connections are returned"
    );
}

/// A pool handed back to a caller must count as used even when no connection is
/// acquired from it. Re-authentication and lookup both hand out a warm pool, so
/// a pool that only ever sees those calls must still stay inside the retention
/// window rather than being disposed on the timestamp of its last acquire.
#[tokio::test]
async fn handing_out_a_pool_refreshes_retention_without_acquiring_a_connection() {
    let dynamic_configuration = TestConfiguration::default();
    let setup_config = setup_configuration();
    let pool_manager = build_shared_pool_manager(&setup_config);
    let user = setup_config.postgres_system_user().to_owned();

    pool_manager
        .allocate_data_pool(&user, "", &dynamic_configuration)
        .unwrap();

    // Re-authentication reuses the warm pool instead of rebuilding it.
    sleep(BEYOND_RETENTION).await;
    pool_manager
        .allocate_data_pool(&user, "", &dynamic_configuration)
        .unwrap();
    pool_manager.clean_unused_pools(RETENTION);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_ok(),
        "re-authentication must refresh retention even when no connection is acquired"
    );

    // Looking the pool up hands it to a caller about to serve a request.
    sleep(BEYOND_RETENTION).await;
    pool_manager
        .get_data_pool(&user, &dynamic_configuration)
        .unwrap();
    pool_manager.clean_unused_pools(RETENTION);

    assert!(
        pool_manager
            .get_data_pool(&user, &dynamic_configuration)
            .is_ok(),
        "looking a pool up must refresh retention even when no connection is acquired"
    );
}

/// A pool handed out between the retention snapshot and the removal must
/// survive: the disposal predicate is re-checked while the entry is locked.
/// Only the predicate is asserted here -- the interleaving itself needs the
/// entry replaced mid-sweep, which has no deterministic hook.
#[tokio::test]
async fn sweep_disposes_only_pools_still_idle_at_removal_time() {
    let dynamic_configuration = TestConfiguration::default();
    let pool_manager = build_shared_pool_manager(&setup_configuration());

    pool_manager
        .allocate_data_pool("racing-user", "", &dynamic_configuration)
        .unwrap();
    pool_manager
        .allocate_data_pool("idle-user", "", &dynamic_configuration)
        .unwrap();

    sleep(BEYOND_RETENTION).await;
    pool_manager
        .get_data_pool("racing-user", &dynamic_configuration)
        .unwrap();

    pool_manager.clean_unused_pools(RETENTION);

    assert!(
        pool_manager
            .get_data_pool("racing-user", &dynamic_configuration)
            .is_ok(),
        "a pool touched before removal must survive the sweep"
    );
    assert!(
        pool_manager
            .get_data_pool("idle-user", &dynamic_configuration)
            .is_err(),
        "a pool left idle past the retention window must still be disposed"
    );
}
