/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/command_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::{
        aggregate, coll_stats, collection_cmd, constant, count, delete, distinct, find,
        find_and_modify, indexing, insert, list_collections, update, validate_cmd,
    },
    test_setup::initialize,
};
use mongodb::error::Error;

#[tokio::test]
async fn insert_one() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_insert_one").await?;

    insert::validate_insert_one(&db).await
}

#[tokio::test]
async fn insert_many() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_insert_many").await?;

    insert::validate_insert_many(&db).await
}

#[tokio::test]
async fn find() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_find").await?;

    find::validate_find(&db).await
}

#[tokio::test]
async fn aggregate() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_aggregate").await?;

    aggregate::validate_aggregate(&db).await
}

#[tokio::test]
async fn update_one() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_update_one").await?;

    update::validate_update_one(&db).await
}

#[tokio::test]
async fn update_many() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_update_many").await?;

    update::validate_update_many(&db).await
}

#[tokio::test]
async fn delete_one() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_delete_one").await?;

    delete::validate_delete_one(&db).await
}

#[tokio::test]
async fn delete_many() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_delete_many").await?;

    delete::validate_delete_many(&db).await
}

#[tokio::test]
async fn list_collections() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_list_collections").await?;

    list_collections::validate_list_collections(&db).await
}

#[tokio::test]
async fn list_indexes() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_list_indexes").await?;

    indexing::validate_list_indexes(&db).await
}

#[tokio::test]
async fn rw_concern() -> Result<(), Error> {
    let client = initialize::initialize().await;

    constant::validate_rw_concern(&client).await
}

#[tokio::test]
async fn get_log() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_get_log").await?;

    constant::validate_get_log(&db).await
}

#[tokio::test]
async fn validate() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_validate").await?;

    validate_cmd::validate_command_validate(&db).await
}

#[tokio::test]
async fn is_db_grid() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_is_db_grid").await?;

    constant::validate_is_db_grid(&db).await
}

#[tokio::test]
async fn find_and_modify() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_find_and_modify").await?;

    find_and_modify::validate_find_and_modify(&db).await
}

#[tokio::test]
async fn distinct() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_distinct").await?;

    distinct::validate_distinct(&db).await
}

#[tokio::test]
async fn create_indexes() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_create_indexes").await?;

    indexing::validate_create_indexes(&db).await
}

#[tokio::test]
async fn count() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_count").await?;

    count::validate_count(&db).await
}

#[tokio::test]
async fn create() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_create").await?;

    collection_cmd::validate_create(&db).await
}

#[tokio::test]
async fn host_info() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_host_info").await?;

    constant::validate_host_info(&db).await
}

#[tokio::test]
async fn get_cmd_line_opts() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_get_cmd_line_opts").await?;

    constant::validate_get_cmd_line_opts(&db).await
}

#[tokio::test]
async fn coll_stats() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_coll_stats").await?;

    coll_stats::validate_coll_stats(&db).await
}

#[tokio::test]
async fn drop() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_drop").await?;

    collection_cmd::validate_drop(&db).await
}

#[tokio::test]
async fn drop_indexes() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_drop_indexes").await?;

    indexing::validate_drop_indexes(&db).await
}

#[tokio::test]
async fn shard_collections() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_shard_collections").await?;

    collection_cmd::validate_shard_collections(&db).await
}
