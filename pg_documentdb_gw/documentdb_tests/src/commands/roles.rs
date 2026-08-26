/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/roles.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::Database;

use crate::utils::commands;

pub async fn validate_create_role_of_reserved_name(db: &Database, reserved_role_names: &[&str]) {
    for role_name in reserved_role_names {
        commands::execute_command_and_validate_error(
            db,
            doc! {
                "createRole": role_name,
                "roles": ["readAnyDatabase"],
                "privileges": []
            },
            2,
            &format!(
                "Role name '{role_name}' is reserved and can't be used as a custom role name."
            ),
            "BadValue",
        )
        .await;
    }
}

pub async fn validate_create_role_of_native_built_in_name(
    db: &Database,
    native_builtin_role_names: &[&str],
) {
    for role_name in native_builtin_role_names {
        commands::execute_command_and_validate_error(
            db,
            doc! {
                "createRole": role_name,
                "roles": ["readAnyDatabase"],
                "privileges": []
            },
            2,
            &format!(
                "Role name '{role_name}' is a built-in role and can't be used as a custom role name."
            ),
            "BadValue",
        )
        .await;
    }
}

pub async fn validate_drop_role_of_reserved_name(db: &Database, reserved_role_names: &[&str]) {
    for role_name in reserved_role_names {
        commands::execute_command_and_validate_error(
            db,
            doc! {
                "dropRole": role_name
            },
            31,
            "The specified role does not exist.",
            "RoleNotFound",
        )
        .await;
    }
}

pub async fn validate_drop_role_of_native_built_in_name(
    db: &Database,
    native_builtin_role_names: &[&str],
) {
    for role_name in native_builtin_role_names {
        commands::execute_command_and_validate_error(
            db,
            doc! {
                "dropRole": role_name
            },
            2,
            &format!("Cannot drop built-in role '{role_name}'."),
            "BadValue",
        )
        .await;
    }
}
