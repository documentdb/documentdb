/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/multi_connect_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::multi_connect, test_setup::initialize};
use tokio::task::JoinSet;

#[tokio::test]
async fn multi_connect() {
    let mut set = JoinSet::new();
    for _ in 0..10 {
        set.spawn(async {
            let db = initialize::initialize_with_db("test").await?;
            multi_connect::validate_multi_connect(&db).await
        });
    }
    while (set.join_next().await).is_some() {}
}
