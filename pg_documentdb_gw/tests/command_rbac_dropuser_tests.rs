/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * tests/command_rbac_dropuser_tests.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod common;

use bson::doc;
use uuid::Uuid;

use crate::common::{rbac_utils, validation_utils};

#[tokio::test]
async fn test_drop_user() -> Result<(), mongodb::error::Error> {
    let client = common::initialize().await;
    let db_name = "admin";
    let db = client.database(db_name);
    let username = format!("user_{}", Uuid::new_v4().to_string().replace("-", ""));
    let user_id = format!("{}.{}", db_name, username);
    let role = "readAnyDatabase";

    db.run_command(doc! {
        "createUser": &username,
        "pwd": "Valid$1Pass",
        "roles": [ { "role": role, "db": db_name } ]
    })
    .await?;

    let users_before = db
        .run_command(doc! {
            "usersInfo": &username
        })
        .await?;

    assert!(
        rbac_utils::user_exists(&users_before, &user_id),
        "User should exist before drop"
    );

    db.run_command(doc! {
        "dropUser": &username
    })
    .await?;

    let users_after = db
        .run_command(doc! {
            "usersInfo": &username
        })
        .await?;

    assert!(
        !rbac_utils::user_exists(&users_after, &user_id),
        "User should not exist after drop"
    );

    Ok(())
}

#[tokio::test]
async fn test_cannot_drop_system_users() -> Result<(), mongodb::error::Error> {
    let client = common::initialize().await;
    let db = client.database("drop_user");

    let system_users = vec![
        ("documentdb_bg_worker_role", 2, "Invalid username."),
        (
            "documentdb_admin_role",
            16909442,
            "role \"documentdb_admin_role\" cannot be dropped because some objects depend on it",
        ),
        (
            "documentdb_readonly_role",
            16909442,
            "role \"documentdb_readonly_role\" cannot be dropped because some objects depend on it",
        ),
    ];

    for (user, error_code, error_message) in system_users {
        validation_utils::execute_command_and_validate_error(
            &db,
            doc! {
                "dropUser": user
            },
            error_code,
            error_message,
        )
        .await;
    }

    Ok(())
}
