/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/users.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client, Database};
use uuid::Uuid;

use crate::utils::{commands, users};

pub async fn validate_create_user(client: &Client) -> Result<(), Error> {
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

    let users = db
        .run_command(doc! {
            "usersInfo": &username
        })
        .await?;

    users::validate_user(&users, &user_id, &username, db_name, role);

    db.run_command(doc! {
        "dropUser": &username
    })
    .await?;

    Ok(())
}

pub async fn validate_drop_user(client: &Client) -> Result<(), Error> {
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
        users::user_exists(&users_before, &user_id),
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
        !users::user_exists(&users_after, &user_id),
        "User should not exist after drop"
    );

    Ok(())
}

pub async fn validate_cannot_drop_system_users(db: &Database) -> Result<(), Error> {
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
        commands::execute_command_and_validate_error(
            db,
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

pub async fn validate_update_user_password(client: &Client) -> Result<(), Error> {
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

    assert!(users::user_exists(&users_before, &user_id));

    db.run_command(doc! {
        "updateUser": &username,
        "pwd": "Other$1Pass",
    })
    .await?;

    let users_after = db
        .run_command(doc! {
            "usersInfo": &username
        })
        .await?;

    users::validate_user(&users_after, &user_id, &username, db_name, role);

    db.run_command(doc! {
        "dropUser": &username
    })
    .await?;

    Ok(())
}

pub async fn validate_users_info(client: &Client) -> Result<(), Error> {
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

    let users = db
        .run_command(doc! {
            "usersInfo": 1
        })
        .await?;

    assert!(
        !users.is_empty(),
        "non-empty users should be returned from usersInfo"
    );

    assert!(
        users::user_exists(&users, &user_id),
        "test user should be returned in usersInfo"
    );

    assert!(
        !users::user_exists(&users, "documentdb_bg_worker_role"),
        "documentdb_bg_worker_role should not be returned in usersInfo"
    );

    assert!(
        !users::user_exists(&users, "documentdb_admin_role"),
        "documentdb_admin_role should not be returned in usersInfo"
    );

    db.run_command(doc! {
        "dropUser": &username
    })
    .await?;

    Ok(())
}

pub async fn validate_createuser_with_bad_password(db: &Database) -> Result<(), Error> {
    let user_id = "admin.bad_pwd_user";

    let users = db.run_command(doc! { "usersInfo": 1 }).await?;

    if users::user_exists(&users, user_id) {
        db.run_command(doc! { "dropUser": "bad_pwd_user" }).await?;
    }

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "createUser": "bad_pwd_user",
            "pwd": "weak",
            "roles": [ { "role": "readAnyDatabase", "db": "admin" } ]
        },
        2,
        "Invalid password, use a different password.",
    )
    .await;

    let users = db.run_command(doc! { "usersInfo": 1 }).await?;
    assert!(!users::user_exists(&users, user_id));

    Ok(())
}

pub async fn validate_usersinfo_with_foralldbs(db: &Database) -> Result<(), Error> {
    let result = db
        .run_command(doc! { "usersInfo": {"forAllDBs": true} })
        .await?;
    assert_eq!(result.get_i32("ok").unwrap(), 1);
    assert!(
        result.get_array("users").is_ok(),
        "Should return users array"
    );

    Ok(())
}

pub async fn validate_usersinfo_with_user_and_db(db: &Database) -> Result<(), Error> {
    let test_user = "test_user_with_db";
    let user_id = format!("admin.{test_user}");

    let users = db.run_command(doc! {"usersInfo": 1}).await?;

    if users::user_exists(&users, &user_id) {
        db.run_command(doc! {"dropUser": test_user}).await?;
    }

    let result = db
        .run_command(doc! {
            "createUser": test_user,
            "pwd": "New$1Pass",
            "roles": [{"role": "readAnyDatabase", "db": "admin"}]
        })
        .await?;
    assert_eq!(result.get_i32("ok").unwrap(), 1);

    let response = db
        .run_command(doc! {
            "usersInfo": {
                "user": test_user,
                "db": "admin"
            }
        })
        .await?;
    assert_eq!(response.get_i32("ok").unwrap(), 1);
    assert!(
        users::user_exists(&response, &user_id),
        "Should find the specific user"
    );

    db.run_command(doc! {"dropUser": test_user}).await?;

    Ok(())
}

pub async fn validate_usersinfo_with_missing_db_or_user(db: &Database) -> Result<(), Error> {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "usersInfo": {
                "user": "test_user"
            }
        },
        2,
        "'usersInfo' document must contain both 'user' and 'db' together.",
    )
    .await;

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "usersInfo": {
                "db": "admin"
            }
        },
        2,
        "'usersInfo' document must contain both 'user' and 'db' together.",
    )
    .await;

    Ok(())
}

pub async fn validate_usersinfo_with_empty_document(db: &Database) -> Result<(), Error> {
    commands::execute_command_and_validate_error(
        db,
        doc! { "usersInfo": {} },
        2,
        "'usersInfo' document must contain either 'forAllDBs: true', or 'user' and 'db'.",
    )
    .await;

    Ok(())
}

pub async fn validate_usersinfo_with_all_fields(db: &Database) -> Result<(), Error> {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "usersInfo": {
                "forAllDBs": true,
                "user": "test_user",
                "db": "admin"
            }
        },
        2,
        "'usersInfo' document must contain either 'forAllDBs: true', or 'user' and 'db'.",
    )
    .await;

    Ok(())
}

pub async fn validate_createuser_of_existing(db: &Database) -> Result<(), Error> {
    let test_user = "existing_user_test";
    let user_id = format!("admin.{test_user}");

    let users = db.run_command(doc! {"usersInfo": 1}).await?;

    if users::user_exists(&users, &user_id) {
        db.run_command(doc! {"dropUser": test_user}).await?;
    }

    let result = db
        .run_command(doc! {
            "createUser": test_user,
            "pwd": "Valid$1Pass",
            "roles": [{"role": "readAnyDatabase", "db": "admin"}]
        })
        .await?;
    assert_eq!(result.get_i32("ok").unwrap(), 1);

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "createUser": test_user,
            "pwd": "Another$1Pass",
            "roles": [{"role": "readAnyDatabase", "db": "admin"}]
        },
        51003,
        "The specified user already exists.",
    )
    .await;

    db.run_command(doc! {"dropUser": test_user}).await?;

    Ok(())
}

pub async fn validate_dropuser_of_not_existing(db: &Database) -> Result<(), Error> {
    let test_user = "non_existent_user_drop";
    let user_id = format!("admin.{test_user}");

    let users = db.run_command(doc! {"usersInfo": 1}).await?;

    if users::user_exists(&users, &user_id) {
        db.run_command(doc! {"dropUser": test_user}).await?;
    }

    commands::execute_command_and_validate_error(
        db,
        doc! { "dropUser": test_user },
        11,
        "The specified user does not exist.",
    )
    .await;

    Ok(())
}

pub async fn validate_drop_system_user(db: &Database) -> Result<(), Error> {
    commands::execute_command_and_validate_error(
        db,
        doc! { "dropUser": "replication" },
        2,
        "Invalid username.",
    )
    .await;

    Ok(())
}

pub async fn validate_usersinfo_excludes_system_user(db: &Database) -> Result<(), Error> {
    let users = db.run_command(doc! { "usersInfo": 1 }).await?;
    assert_eq!(users.get_i32("ok").unwrap(), 1);

    assert!(
        !users::user_exists(&users, "replication"),
        "non-login role should not be returned in usersInfo"
    );

    Ok(())
}

pub async fn validate_update_user_of_not_existing(db: &Database) -> Result<(), Error> {
    let test_user = "non_existent_user_update";
    let user_id = format!("admin.{test_user}");

    let users = db.run_command(doc! {"usersInfo": 1}).await?;

    if users::user_exists(&users, &user_id) {
        db.run_command(doc! {"dropUser": test_user}).await?;
    }

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "updateUser": test_user,
            "pwd": "NewPassword$1"
        },
        11,
        "The specified user does not exist.",
    )
    .await;

    Ok(())
}
