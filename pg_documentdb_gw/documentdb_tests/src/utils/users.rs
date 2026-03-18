/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/utils/users.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{Bson, Document};

pub fn user_exists(doc: &Document, expected_user_id: &str) -> bool {
    if let Ok(users) = doc.get_array("users") {
        for user in users {
            if let Some(user_doc) = user.as_document() {
                if let Some(id) = user_doc.get("_id").and_then(Bson::as_str) {
                    if id == expected_user_id {
                        return true;
                    }
                }
            }
        }
    }
    false
}

pub fn validate_user(
    doc: &Document,
    expected_user_id: &str,
    expected_user: &str,
    expected_db: &str,
    expected_role: &str,
) -> std::result::Result<(), bson::document::ValueAccessError> {
    let users = doc.get_array("users")?;

    let mut user_found = false;
    for user in users {
        if let Some(user_doc) = user.as_document() {
            if let Some(id) = user_doc.get("_id").and_then(Bson::as_str) {
                if id == expected_user_id {
                    user_found = true;

                    match user_doc.get("user").and_then(Bson::as_str) {
                        Some(user_name) => {
                            assert_eq!(user_name, expected_user, "user name mismatch");
                        }
                        None => panic!("Expected 'user' field is missing or not a string"),
                    }

                    match user_doc.get("db").and_then(Bson::as_str) {
                        Some(db_name) => assert_eq!(db_name, expected_db, "database name mismatch"),
                        None => panic!("Expected 'db' field is missing or not a string"),
                    }

                    let roles = user_doc.get_array("roles")?;
                    let mut role_found = false;

                    for role in roles {
                        if let Some(role_doc) = role.as_document() {
                            if let Some(role_name) = role_doc.get("role").and_then(Bson::as_str) {
                                if role_name == expected_role {
                                    role_found = true;
                                    if let Some(role_db) = role_doc.get("db").and_then(Bson::as_str)
                                    {
                                        assert_eq!(role_db, expected_db, "role database mismatch");
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    assert!(role_found, "expected role '{expected_role}' not found");
                }
            }
        }
    }
    assert!(user_found, "user with id '{expected_user_id}' not found");

    Ok(())
}
