/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/utils/rbac_validator.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, oid::ObjectId, Document};
use mongodb::{error::Error, Client};

use crate::utils::commands;

const UNAUTHORIZED_CODE: i32 = 13;
const UNAUTHORIZED_MSG: &str = "User is not authorized to perform this action";
const UNAUTHORIZED_CODE_NAME: &str = "Unauthorized";

/// Whether a command is expected to be authorized or denied for the test user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthorizationStatus {
    Authorized,
    Denied,
}

/// Helper for validating RBAC authorization on a specific database and collection.
///
/// Construct via [`RbacValidator::new`] with a user [`Client`], an admin [`Client`],
/// a logical database name, and a collection name.  The validator derives
/// database handles internally so individual validate methods do not need an
/// extra `admin_db` parameter.
pub struct RbacValidator<'a> {
    user_client: &'a Client,
    admin_client: &'a Client,
    db_name: &'a str,
    collection_name: &'a str,
}

impl<'a> RbacValidator<'a> {
    pub const fn new(
        user_client: &'a Client,
        admin_client: &'a Client,
        default_db_name: &'a str,
        default_collection_name: &'a str,
    ) -> Self {
        Self {
            user_client,
            admin_client,
            db_name: default_db_name,
            collection_name: default_collection_name,
        }
    }

    // -------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------

    pub async fn populate_test_data(&self) -> Result<(), Error> {
        let db = self.admin_client.database(self.db_name);
        db.drop().await?;

        let insert_result = db
            .run_command(doc! {
                "insert": self.collection_name,
                "documents": [
                    {"_id": 1, "value": 1},
                    {"_id": 2, "value": 2},
                    {"_id": 3, "value": 3}
                ]
            })
            .await?;
        assert!(
            matches!(insert_result.get("ok"), Some(bson::Bson::Double(1.0))),
            "Insert should succeed with admin credentials, got: {insert_result:?}"
        );
        assert_eq!(
            insert_result.get_i32("n"),
            Ok(3),
            "Insert should report 3 documents inserted"
        );

        Ok(())
    }

    // -------------------------------------------------------------------
    // CRUD operations
    // -------------------------------------------------------------------

    pub async fn validate_find(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let cmd = doc! { "find": self.collection_name, "filter": {} };
        if let Some(doc) = self.validate_command(cmd, expected_auth, "find").await? {
            let batch = doc["cursor"]["firstBatch"].as_array();
            assert!(
                batch.is_some_and(|b| !b.is_empty()),
                "find: firstBatch should not be empty"
            );
        }
        Ok(())
    }

    pub async fn validate_count(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let cmd = doc! { "count": self.collection_name, "query": {} };
        if let Some(doc) = self.validate_command(cmd, expected_auth, "count").await? {
            assert!(doc.get_i32("n").unwrap_or(0) > 0, "count n should be > 0");
        }
        Ok(())
    }

    pub async fn validate_insert(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let id = ObjectId::new();
        let cmd = doc! {
            "insert": self.collection_name,
            "documents": [{"_id": id}]
        };
        if let Some(doc) = self.validate_command(cmd, expected_auth, "insert").await? {
            assert!(doc.get_i32("n").unwrap_or(0) > 0, "insert n should be > 0");
        }

        self.admin_client
            .database(self.db_name)
            .run_command(doc! {
                "delete": self.collection_name,
                "deletes": [{"q": {"_id": id}, "limit": 1}]
            })
            .await?;
        Ok(())
    }

    pub async fn validate_update(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let cmd = doc! {
            "update": self.collection_name,
            "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 0}}}]
        };
        if let Some(doc) = self.validate_command(cmd, expected_auth, "update").await? {
            assert!(
                doc.get_i32("nModified").unwrap_or(0) > 0,
                "update nModified should be > 0"
            );
        }

        self.admin_client
            .database(self.db_name)
            .run_command(doc! {
                "update": self.collection_name,
                "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 1}}}]
            })
            .await?;
        Ok(())
    }

    pub async fn validate_find_and_modify(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! {
            "findAndModify": self.collection_name,
            "query": {"_id": 1},
            "update": {"$set": {"value": 0}}
        };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "findAndModify")
            .await?
        {
            assert!(
                doc.get("value").is_some(),
                "findAndModify should return data"
            );
        }

        self.admin_client
            .database(self.db_name)
            .run_command(doc! {
                "update": self.collection_name,
                "updates": [{"q": {"_id": 1}, "u": {"$set": {"value": 1}}}]
            })
            .await?;
        Ok(())
    }

    pub async fn validate_delete(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let id = ObjectId::new();
        self.admin_client
            .database(self.db_name)
            .run_command(doc! {
                "insert": self.collection_name,
                "documents": [{"_id": id}]
            })
            .await?;

        let cmd = doc! {
            "delete": self.collection_name,
            "deletes": [{"q": {"_id": id}, "limit": 1}]
        };
        if let Some(doc) = self.validate_command(cmd, expected_auth, "delete").await? {
            assert!(doc.get_i32("n").unwrap_or(0) > 0, "delete n should be > 0");
        }

        self.admin_client
            .database(self.db_name)
            .run_command(doc! {
                "delete": self.collection_name,
                "deletes": [{"q": {"_id": id}, "limit": 1}]
            })
            .await?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // DB command operations
    // -------------------------------------------------------------------

    pub async fn validate_distinct(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let cmd = doc! { "distinct": self.collection_name, "key": "_id" };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "distinct")
            .await?
        {
            let values = doc.get_array("values");
            assert!(
                values.is_ok_and(|v| !v.is_empty()),
                "distinct values should not be empty"
            );
        }
        Ok(())
    }

    pub async fn validate_list_collections(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! { "listCollections": 1, "nameOnly": true };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "listCollections")
            .await?
        {
            let batch = doc["cursor"]["firstBatch"].as_array();
            assert!(
                batch.is_some_and(|b| !b.is_empty()),
                "listCollections should not be empty"
            );
        }
        Ok(())
    }

    pub async fn validate_coll_stats(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! { "collStats": self.collection_name };
        let expected_ns = self.namespace();
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "collStats")
            .await?
        {
            assert_eq!(
                doc.get_str("ns"),
                Ok(expected_ns.as_str()),
                "collStats ns mismatch"
            );
        }
        Ok(())
    }

    pub async fn validate_list_databases(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! { "listDatabases": 1 };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "listDatabases")
            .await?
        {
            let databases = doc.get_array("databases");
            assert!(
                databases.is_ok_and(|d| !d.is_empty()),
                "listDatabases should not be empty"
            );
        }
        Ok(())
    }

    pub async fn validate_db_stats(&self, expected_auth: AuthorizationStatus) -> Result<(), Error> {
        let cmd = doc! { "dbStats": 1 };
        let db_name = self.db_name;
        if let Some(doc) = self.validate_command(cmd, expected_auth, "dbStats").await? {
            assert_eq!(doc.get_str("db"), Ok(db_name), "dbStats db name mismatch");
        }
        Ok(())
    }

    pub async fn validate_drop_collection(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let admin_db = self.admin_client.database(self.db_name);
        let temp_collection = "rbac_drop_temp";
        admin_db
            .run_command(doc! { "create": temp_collection })
            .await?;

        let cmd = doc! { "drop": temp_collection };
        self.validate_command(cmd, expected_auth, "drop").await?;

        if expected_auth == AuthorizationStatus::Authorized {
            assert!(
                !self
                    .collection_exists(self.db_name, temp_collection)
                    .await?,
                "drop: collection should not exist after authorized drop"
            );
        } else {
            assert!(
                self.collection_exists(self.db_name, temp_collection)
                    .await?,
                "drop: collection should still exist after unauthorized drop"
            );
            admin_db
                .run_command(doc! { "drop": temp_collection })
                .await?;
        }
        Ok(())
    }

    pub async fn validate_drop_database(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let temp_db = self.admin_client.database("rbac_drop_temp_db");
        temp_db.run_command(doc! { "create": "seed" }).await?;

        let test_user_temp_db = self.user_client.database("rbac_drop_temp_db");
        let cmd = doc! { "dropDatabase": 1 };
        if expected_auth == AuthorizationStatus::Authorized {
            let doc = test_user_temp_db.run_command(cmd).await?;
            assert_eq!(
                doc.get_str("dropped"),
                Ok("rbac_drop_temp_db"),
                "dropDatabase should report dropped database name"
            );
        } else {
            commands::execute_command_and_validate_error(
                &test_user_temp_db,
                cmd,
                UNAUTHORIZED_CODE,
                UNAUTHORIZED_MSG,
                UNAUTHORIZED_CODE_NAME,
            )
            .await;
            assert!(
                self.collection_exists("rbac_drop_temp_db", "seed").await?,
                "dropDatabase: temp database should still exist after unauthorized drop"
            );
            temp_db.run_command(doc! { "dropDatabase": 1 }).await?;
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Aggregate read operations
    // -------------------------------------------------------------------

    pub async fn validate_aggregate_count(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! {
            "aggregate": self.collection_name,
            "pipeline": [{"$count": "total"}],
            "cursor": {}
        };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "aggregate ($count)")
            .await?
        {
            let batch = doc["cursor"]["firstBatch"].as_array();
            assert!(
                batch.is_some_and(|b| !b.is_empty()),
                "aggregate firstBatch should not be empty"
            );
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Aggregate write operations
    // -------------------------------------------------------------------

    pub async fn validate_aggregate_out(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let admin_db = self.admin_client.database(self.db_name);
        let cmd = doc! {
            "aggregate": self.collection_name,
            "pipeline": [{"$match": {}}, {"$out": "rbac_output_temp"}],
            "cursor": {}
        };
        self.validate_command(cmd, expected_auth, "aggregate ($out)")
            .await?;

        if expected_auth == AuthorizationStatus::Authorized {
            assert!(
                self.collection_exists(self.db_name, "rbac_output_temp")
                    .await?,
                "aggregate $out: output collection should exist after authorized run"
            );
            admin_db
                .run_command(doc! { "drop": "rbac_output_temp" })
                .await?;
        } else {
            assert!(
                !self
                    .collection_exists(self.db_name, "rbac_output_temp")
                    .await?,
                "aggregate $out: output collection should not exist after unauthorized run"
            );
        }
        Ok(())
    }

    pub async fn validate_aggregate_merge(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let admin_db = self.admin_client.database(self.db_name);
        let cmd = doc! {
            "aggregate": self.collection_name,
            "pipeline": [{"$match": {}}, {"$merge": {"into": "rbac_merge_temp"}}],
            "cursor": {}
        };
        self.validate_command(cmd, expected_auth, "aggregate ($merge)")
            .await?;

        if expected_auth == AuthorizationStatus::Authorized {
            assert!(
                self.collection_exists(self.db_name, "rbac_merge_temp")
                    .await?,
                "aggregate $merge: output collection should exist after authorized run"
            );
            admin_db
                .run_command(doc! { "drop": "rbac_merge_temp" })
                .await?;
        } else {
            assert!(
                !self
                    .collection_exists(self.db_name, "rbac_merge_temp")
                    .await?,
                "aggregate $merge: output collection should not exist after unauthorized run"
            );
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Index operations
    // -------------------------------------------------------------------

    pub async fn validate_list_indexes(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        // The default _id index always exists after populate_test_data,
        // so no custom index creation is needed.
        let cmd = doc! { "listIndexes": self.collection_name };
        if let Some(doc) = self
            .validate_command(cmd, expected_auth, "listIndexes")
            .await?
        {
            let batch = doc["cursor"]["firstBatch"].as_array();
            assert!(
                batch.is_some_and(|b| !b.is_empty()),
                "listIndexes should not be empty"
            );
        }
        Ok(())
    }

    pub async fn validate_create_indexes(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! {
            "createIndexes": self.collection_name,
            "indexes": [{"key": {"value": 1}, "name": "rbac_create_indexes_idx"}]
        };
        self.validate_command(cmd, expected_auth, "createIndexes")
            .await?;

        if expected_auth == AuthorizationStatus::Authorized {
            assert!(
                self.index_exists(
                    self.db_name,
                    self.collection_name,
                    "rbac_create_indexes_idx"
                )
                .await?,
                "createIndexes: index should exist after authorized create"
            );
            self.admin_client
                .database(self.db_name)
                .run_command(doc! {
                    "dropIndexes": self.collection_name,
                    "index": "rbac_create_indexes_idx"
                })
                .await?;
        }
        Ok(())
    }

    pub async fn validate_drop_indexes(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let admin_db = self.admin_client.database(self.db_name);
        admin_db
            .run_command(doc! {
                "createIndexes": self.collection_name,
                "indexes": [{"key": {"value": 1}, "name": "rbac_drop_indexes_idx"}]
            })
            .await?;

        let cmd = doc! {
            "dropIndexes": self.collection_name,
            "index": "rbac_drop_indexes_idx"
        };
        self.validate_command(cmd, expected_auth, "dropIndexes")
            .await?;

        if expected_auth == AuthorizationStatus::Authorized {
            assert!(
                !self
                    .index_exists(self.db_name, self.collection_name, "rbac_drop_indexes_idx")
                    .await?,
                "dropIndexes: index should not exist after authorized drop"
            );
        } else {
            // Clean up the index created by admin since the user could not
            // drop it.
            admin_db
                .run_command(doc! {
                    "dropIndexes": self.collection_name,
                    "index": "rbac_drop_indexes_idx"
                })
                .await?;
        }
        Ok(())
    }

    // -------------------------------------------------------------------
    // Sharding operations
    // -------------------------------------------------------------------

    pub async fn validate_shard_collection(
        &self,
        expected_auth: AuthorizationStatus,
    ) -> Result<(), Error> {
        let cmd = doc! { "shardCollection": self.namespace(), "key": {"_id": "hashed"} };
        self.validate_command(cmd, expected_auth, "shardCollection")
            .await?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------

    fn namespace(&self) -> String {
        format!("{}.{}", self.db_name, self.collection_name)
    }

    async fn collection_exists(&self, db_name: &str, collection_name: &str) -> Result<bool, Error> {
        let result = self
            .admin_client
            .database(db_name)
            .run_command(doc! {
                "listCollections": 1,
                "filter": { "name": collection_name }
            })
            .await?;
        let is_present = result["cursor"]["firstBatch"]
            .as_array()
            .is_some_and(|batch| !batch.is_empty());
        Ok(is_present)
    }

    async fn index_exists(
        &self,
        db_name: &str,
        collection_name: &str,
        index_name: &str,
    ) -> Result<bool, Error> {
        let result = self
            .admin_client
            .database(db_name)
            .run_command(doc! { "listIndexes": collection_name })
            .await?;
        let found = result["cursor"]["firstBatch"]
            .as_array()
            .is_some_and(|batch| {
                batch.iter().any(|idx| {
                    idx.as_document().and_then(|d| d.get_str("name").ok()) == Some(index_name)
                })
            });
        Ok(found)
    }

    async fn validate_command(
        &self,
        cmd: Document,
        expected_auth: AuthorizationStatus,
        operation: &str,
    ) -> Result<Option<Document>, Error> {
        let db = self.user_client.database(self.db_name);
        if expected_auth == AuthorizationStatus::Authorized {
            let doc = db.run_command(cmd).await.map_err(|e| {
                // Preserve the original error while adding operation context
                eprintln!("{operation} should succeed for authorized user, but got error: {e}");
                e
            })?;
            Ok(Some(doc))
        } else {
            commands::execute_command_and_validate_error(
                &db,
                cmd,
                UNAUTHORIZED_CODE,
                UNAUTHORIZED_MSG,
                UNAUTHORIZED_CODE_NAME,
            )
            .await;
            Ok(None)
        }
    }
}
