/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/query_catalog.rs
 *
 *-------------------------------------------------------------------------
 */

use serde::Deserialize;

#[derive(Debug, Deserialize, Default, Clone)]
pub struct QueryCatalog {
    // auth.rs
    pub authenticate_with_scram_sha256: String,
    pub salt_and_iterations: String,
    pub authenticate_with_token: String,

    // dataapi.rs (Not needed for OSS)
    pub authenticate_with_pwd: String,
    pub bson_json_to_bson: String,
    pub bson_to_json_string: String,

    // pg_configuration.rs
    pub pg_settings: String,
    pub pg_is_in_recovery: String,
    pub extension_versions: String,

    // explain/mod.rs
    pub explain: String, // Has 2 params
    pub set_explain_all_tasks_true: String,
    pub set_explain_all_plans_true: String,
    pub find_coalesce: String,
    pub find_operator: String,
    pub find_bson_text_meta_qual: String,
    pub find_bson_repath_and_build: String,

    // query_diagnostics.rs
    pub bson_dollar_project_output_regex: String,
    pub index_condition_split_regex: String,
    pub runtime_condition_split_regex: String,
    pub sort_condition_split_regex: String,
    pub single_index_condition_regex: String,
    pub api_catalog_name_regex: String,
    pub output_count_regex: String,
    pub output_bson_count_aggregate: String,
    pub output_bson_command_count_aggregate: String,

    // client.rs
    pub set_search_path_and_timeout: String,

    // cursor.rs
    pub cursor_get_more: String,
    pub kill_cursors: String,

    // data_description.rs
    pub create_collection_view: String,
    pub drop_database: String,
    pub drop_collection: String,
    pub set_allow_write: String,
    pub shard_collection: String,
    pub rename_collection: String,
    pub coll_mod: String,
    pub unshard_collection: String,
    pub get_shard_map: String,
    pub list_shards: String,

    // data_management.rs
    pub delete: String,
    pub find_cursor_first_page: String,
    pub insert: String,
    pub insert_txn_proc: String,
    pub insert_bulk: String,
    pub aggregate_cursor_first_page: String,
    pub process_update: String,
    pub update_txn_proc: String,
    pub update_bulk: String,
    pub list_databases: String, // Has 1 param
    pub list_collections: String,
    pub validate: String,
    pub find_and_modify: String,
    pub distinct_query: String,
    pub count_query: String,
    pub coll_stats: String,
    pub db_stats: String,
    pub current_op: String,
    pub get_parameter: String,
    pub compact: String,
    pub kill_op: String,
    pub balancer_start: String,
    pub balancer_status: String,
    pub balancer_stop: String,
    pub move_collection: String,

    // indexing.rs
    pub create_indexes_background: String,
    pub check_build_index_status: String,
    pub re_index: String,
    pub drop_indexes: String,
    pub list_indexes_cursor_first_page: String,

    // user.rs
    pub create_user: String,
    pub drop_user: String,
    pub update_user: String,
    pub users_info: String,
    pub connection_status: String,

    // roles.rs
    pub create_role: String,
    pub update_role: String,
    pub drop_role: String,
    pub roles_info: String,

    // tests
    pub create_db_user: String,

    pub scan_types: Vec<String>,
}

impl QueryCatalog {
    // Auth getters
    #[must_use]
    pub fn authenticate_with_scram_sha256(&self) -> &str {
        &self.authenticate_with_scram_sha256
    }

    #[must_use]
    pub fn salt_and_iterations(&self) -> &str {
        &self.salt_and_iterations
    }

    #[must_use]
    pub fn authenticate_with_token(&self) -> &str {
        &self.authenticate_with_token
    }

    // Dataapi getters
    #[must_use]
    pub fn authenticate_with_pwd(&self) -> &str {
        &self.authenticate_with_pwd
    }

    #[must_use]
    pub fn bson_json_to_bson(&self) -> &str {
        &self.bson_json_to_bson
    }

    #[must_use]
    pub fn bson_to_json_string(&self) -> &str {
        &self.bson_to_json_string
    }

    // Dynamic getters
    #[must_use]
    pub fn pg_settings(&self) -> &str {
        &self.pg_settings
    }

    #[must_use]
    pub fn pg_is_in_recovery(&self) -> &str {
        &self.pg_is_in_recovery
    }

    // Topology getter
    #[must_use]
    pub fn extension_versions(&self) -> &str {
        &self.extension_versions
    }

    // Explain getters
    #[must_use]
    pub fn explain(&self, analyze: &str, query_base: &str) -> String {
        self.explain
            .replace("{analyze}", analyze)
            .replace("{query_base}", query_base)
    }

    #[must_use]
    pub fn set_explain_all_tasks_true(&self) -> &str {
        &self.set_explain_all_tasks_true
    }

    #[must_use]
    pub fn set_explain_all_plans_true(&self) -> &str {
        &self.set_explain_all_plans_true
    }

    #[must_use]
    pub fn find_coalesce(&self) -> &str {
        &self.find_coalesce
    }

    #[must_use]
    pub fn find_operator(&self) -> &str {
        &self.find_operator
    }

    #[must_use]
    pub fn find_bson_text_meta_qual(&self) -> &str {
        &self.find_bson_text_meta_qual
    }

    #[must_use]
    pub fn find_bson_repath_and_build(&self) -> &str {
        &self.find_bson_repath_and_build
    }

    // query_diagnostics getters
    #[must_use]
    pub fn bson_dollar_project_output_regex(&self) -> &str {
        &self.bson_dollar_project_output_regex
    }

    #[must_use]
    pub fn index_condition_split_regex(&self) -> &str {
        &self.index_condition_split_regex
    }

    #[must_use]
    pub fn runtime_condition_split_regex(&self) -> &str {
        &self.runtime_condition_split_regex
    }

    #[must_use]
    pub fn sort_condition_split_regex(&self) -> &str {
        &self.sort_condition_split_regex
    }

    #[must_use]
    pub fn single_index_condition_regex(&self) -> &str {
        &self.single_index_condition_regex
    }

    #[must_use]
    pub fn api_catalog_name_regex(&self) -> &str {
        &self.api_catalog_name_regex
    }

    #[must_use]
    pub fn output_count_regex(&self) -> &str {
        &self.output_count_regex
    }

    #[must_use]
    pub fn output_bson_count_aggregate(&self) -> &str {
        &self.output_bson_count_aggregate
    }

    #[must_use]
    pub fn output_bson_command_count_aggregate(&self) -> &str {
        &self.output_bson_command_count_aggregate
    }

    // Client getters
    #[must_use]
    pub fn set_search_path_and_timeout(&self, timeout: &str, transaction_timeout: &str) -> String {
        self.set_search_path_and_timeout
            .replace("{timeout}", timeout)
            .replace("{transaction_timeout}", transaction_timeout)
    }

    // Cursor getters
    #[must_use]
    pub fn cursor_get_more(&self) -> &str {
        &self.cursor_get_more
    }

    // Delete getters
    #[must_use]
    pub fn drop_database(&self) -> &str {
        &self.drop_database
    }

    #[must_use]
    pub fn drop_collection(&self) -> &str {
        &self.drop_collection
    }

    #[must_use]
    pub fn delete(&self) -> &str {
        &self.delete
    }

    #[must_use]
    pub fn set_allow_write(&self) -> &str {
        &self.set_allow_write
    }

    // Indexing getters
    #[must_use]
    pub fn create_indexes_background(&self) -> &str {
        &self.create_indexes_background
    }

    #[must_use]
    pub fn check_build_index_status(&self) -> &str {
        &self.check_build_index_status
    }

    #[must_use]
    pub fn re_index(&self) -> &str {
        &self.re_index
    }

    #[must_use]
    pub fn drop_indexes(&self) -> &str {
        &self.drop_indexes
    }

    #[must_use]
    pub fn list_indexes_cursor_first_page(&self) -> &str {
        &self.list_indexes_cursor_first_page
    }

    // Process getters
    #[must_use]
    pub fn find_cursor_first_page(&self) -> &str {
        &self.find_cursor_first_page
    }

    #[must_use]
    pub fn insert(&self) -> &str {
        &self.insert
    }

    #[must_use]
    pub fn insert_txn_proc(&self) -> &str {
        &self.insert_txn_proc
    }

    #[must_use]
    pub fn insert_bulk(&self) -> &str {
        &self.insert_bulk
    }

    #[must_use]
    pub fn aggregate_cursor_first_page(&self) -> &str {
        &self.aggregate_cursor_first_page
    }

    #[must_use]
    pub fn process_update(&self) -> &str {
        &self.process_update
    }

    #[must_use]
    pub fn update_txn_proc(&self) -> &str {
        &self.update_txn_proc
    }

    #[must_use]
    pub fn update_bulk(&self) -> &str {
        &self.update_bulk
    }

    #[must_use]
    pub fn list_databases(&self, filter_string: &str) -> String {
        self.list_databases
            .replace("{filter_string}", filter_string)
    }

    #[must_use]
    pub fn list_collections(&self) -> &str {
        &self.list_collections
    }

    #[must_use]
    pub fn validate(&self) -> &str {
        &self.validate
    }

    #[must_use]
    pub fn find_and_modify(&self) -> &str {
        &self.find_and_modify
    }

    #[must_use]
    pub fn distinct_query(&self) -> &str {
        &self.distinct_query
    }

    #[must_use]
    pub fn count_query(&self) -> &str {
        &self.count_query
    }

    #[must_use]
    pub fn create_collection_view(&self) -> &str {
        &self.create_collection_view
    }

    #[must_use]
    pub fn coll_stats(&self) -> &str {
        &self.coll_stats
    }

    #[must_use]
    pub fn db_stats(&self) -> &str {
        &self.db_stats
    }

    #[must_use]
    pub fn shard_collection(&self) -> &str {
        &self.shard_collection
    }

    #[must_use]
    pub fn rename_collection(&self) -> &str {
        &self.rename_collection
    }

    #[must_use]
    pub fn current_op(&self) -> &str {
        &self.current_op
    }

    #[must_use]
    pub fn coll_mod(&self) -> &str {
        &self.coll_mod
    }

    #[must_use]
    pub fn get_parameter(&self) -> &str {
        &self.get_parameter
    }

    #[must_use]
    pub fn move_collection(&self) -> &str {
        &self.move_collection
    }

    // User getters
    #[must_use]
    pub fn create_user(&self) -> &str {
        &self.create_user
    }

    #[must_use]
    pub fn drop_user(&self) -> &str {
        &self.drop_user
    }

    #[must_use]
    pub fn update_user(&self) -> &str {
        &self.update_user
    }

    #[must_use]
    pub fn users_info(&self) -> &str {
        &self.users_info
    }

    #[must_use]
    pub fn connection_status(&self) -> &str {
        &self.connection_status
    }

    #[must_use]
    pub fn create_role(&self) -> &str {
        &self.create_role
    }

    #[must_use]
    pub fn update_role(&self) -> &str {
        &self.update_role
    }

    #[must_use]
    pub fn drop_role(&self) -> &str {
        &self.drop_role
    }

    #[must_use]
    pub fn roles_info(&self) -> &str {
        &self.roles_info
    }

    #[must_use]
    pub fn create_db_user(&self, user: &str, pass: &str) -> String {
        self.create_db_user
            .replace("{user}", user)
            .replace("{pass}", pass)
    }

    #[must_use]
    pub const fn scan_types(&self) -> &Vec<String> {
        &self.scan_types
    }

    #[must_use]
    pub fn unshard_collection(&self) -> &str {
        &self.unshard_collection
    }

    #[must_use]
    pub fn get_shard_map(&self) -> &str {
        &self.get_shard_map
    }

    #[must_use]
    pub fn list_shards(&self) -> &str {
        &self.list_shards
    }

    #[must_use]
    pub fn compact(&self) -> &str {
        &self.compact
    }

    #[must_use]
    pub fn kill_op(&self) -> &str {
        &self.kill_op
    }

    #[must_use]
    pub fn kill_cursors(&self) -> &str {
        &self.kill_cursors
    }

    #[must_use]
    pub fn balancer_start(&self) -> &str {
        &self.balancer_start
    }

    #[must_use]
    pub fn balancer_status(&self) -> &str {
        &self.balancer_status
    }

    #[must_use]
    pub fn balancer_stop(&self) -> &str {
        &self.balancer_stop
    }
}

#[must_use]
pub fn create_query_catalog() -> QueryCatalog {
    QueryCatalog {
            // auth.rs
            authenticate_with_scram_sha256: "SELECT documentdb_api_internal.authenticate_with_scram_sha256($1, $2, $3)".to_owned(),
            salt_and_iterations: "SELECT documentdb_api_internal.scram_sha256_get_salt_and_iterations($1)".to_owned(),
            authenticate_with_token: "SELECT documentdb_api_internal.authenticate_token($1, $2)".to_owned(),

            // pg_configuration.rs
            pg_settings: "SELECT name, setting FROM pg_settings WHERE name LIKE 'documentdb.%' OR name IN ('max_connections', 'default_transaction_read_only')".to_owned(),
            pg_is_in_recovery: "SELECT pg_is_in_recovery()".to_owned(),
            extension_versions: "SELECT documentdb_core.bson_build_document('internal', ARRAY[ (SELECT extversion FROM pg_extension WHERE extname = 'documentdb' LIMIT 1), documentdb_api.binary_version() ])".to_owned(),

            // explain/mod.rs
            explain: "EXPLAIN (FORMAT JSON, ANALYZE {analyze}, VERBOSE True, BUFFERS {analyze}, TIMING {analyze}) SELECT document FROM documentdb_api_catalog.bson_aggregation_{query_base}($1, $2)".to_owned(),
            set_explain_all_plans_true: "SET LOCAL documentdb.enableExtendedExplainPlans TO true".to_owned(),
            find_coalesce: "COALESCE(documentdb_api_catalog.bson_array_agg".to_owned(),
            find_operator: "OPERATOR(documentdb_api_catalog.@#%)".to_owned(),
            find_bson_text_meta_qual: "documentdb_api_catalog.bson_text_meta_qual".to_owned(),
            find_bson_repath_and_build: "documentdb_api_catalog.bson_repath_and_build".to_owned(),

            // query_diagnostics.rs
            bson_dollar_project_output_regex: "(documentdb_api_catalog.)?bson_dollar_([^\\(]+)\\([^,]+, 'BSONHEX([\\w\\d]+)'::documentdb_core.bson".to_owned(),
            index_condition_split_regex: "\\(?((\\s+AND\\s+)?(?<expr>\\S+ (OPERATOR\\(\\S+\\)|(@\\S+)) '[^']+'::(documentdb_core.)?bson))+\\)?".to_owned(),
            runtime_condition_split_regex: "\\(?((\\s+AND|OR\\s+)?(?<expr>\\S+ (OPERATOR\\(\\S+\\)|(@\\S+)) '[^']+'::(documentdb_core.)?bson))+\\)?".to_owned(),
            sort_condition_split_regex: "(documentdb_api_catalog\\.)?bson_orderby\\(([^,]+), 'BSONHEX([\\w\\d]+)'::documentdb_core.bson\\)".to_owned(),
            single_index_condition_regex: "(OPERATOR\\()?(documentdb_api_catalog\\.)?(?<operator>@[^\\)\\s]+)\\)?\\s+'BSONHEX(?<queryBson>\\S+)'".to_owned(),
            api_catalog_name_regex: "documentdb_api_catalog.".to_owned(),
            output_count_regex: "BSONSUM('{ \"\" : { \"$numberInt\" : \"1\" } }'::documentdb_core.bson)".to_owned(),
            output_bson_count_aggregate: "bsoncount(1)".to_owned(),
            output_bson_command_count_aggregate: "bsoncommandcount(1)".to_owned(),

            // cursor.rs
            cursor_get_more: "SELECT cursorPage, continuation FROM documentdb_api.cursor_get_more($1, $2, $3)".to_owned(),
            kill_cursors: "SELECT documentdb_api_internal.delete_cursors($1)".to_owned(),

            // client.rs
            set_search_path_and_timeout: "-c search_path=documentdb_api_catalog,documentdb_api,public -c statement_timeout={timeout} -c idle_in_transaction_session_timeout={transaction_timeout}".to_owned(),

            // data_description.rs
            drop_database: "SELECT documentdb_api.drop_database($1)".to_owned(),
            drop_collection: "SELECT documentdb_api.drop_collection($1, $2)".to_owned(),
            set_allow_write: "SET LOCAL documentdb.IsPgReadOnlyForDiskFull to false; SET transaction read write".to_owned(),
            create_collection_view: "SELECT documentdb_api.create_collection_view($1, $2)".to_owned(),
            shard_collection: "SELECT documentdb_api.shard_collection($1, $2, $3, $4)".to_owned(),
            rename_collection: "SELECT documentdb_api.rename_collection($1)".to_owned(),
            coll_mod: "SELECT documentdb_api.coll_mod($1, $2, $3)".to_owned(),
            unshard_collection: "SELECT documentdb_api.unshard_collection($1)".to_owned(),

            // data_management.rs
            delete: "SELECT * FROM documentdb_api.delete($1, $2, $3, NULL)".to_owned(),
            find_cursor_first_page: "SELECT cursorPage, continuation, persistConnection, cursorId FROM documentdb_api.find_cursor_first_page($1, $2)".to_owned(),
            insert: "SELECT * FROM documentdb_api.insert($1, $2, $3, NULL)".to_owned(),
            insert_txn_proc: "CALL documentdb_api.insert_txn_proc($1, $2, $3, NULL)".to_owned(),
            insert_bulk: "CALL documentdb_api.insert_bulk($1, $2, $3, NULL)".to_owned(),
            aggregate_cursor_first_page: "SELECT cursorPage, continuation, persistConnection, cursorId FROM documentdb_api.aggregate_cursor_first_page($1, $2)".to_owned(),
            process_update: "SELECT * FROM documentdb_api.update($1, $2, $3, NULL)".to_owned(),
            update_txn_proc: "CALL documentdb_api.update_txn_proc($1, $2, $3, NULL)".to_owned(),
            update_bulk: "CALL documentdb_api.update_bulk($1, $2, $3, NULL)".to_owned(),
            list_databases: "WITH r1 AS (SELECT DISTINCT database_name AS name
                                FROM documentdb_api_catalog.collections),
                             r2 AS (SELECT documentdb_core.row_get_bson(r1) AS document FROM r1),
                             r3 AS (SELECT document FROM r2 {filter_string}),
                             r4 AS (SELECT COALESCE(documentdb_api_catalog.bson_array_agg(r3.document, ''), '{ \"\": [] }') AS \"databases\",
                                           1.0::float8                                                                        AS \"ok\"
                                    FROM r3)
                        SELECT documentdb_core.row_get_bson(r4) AS document
                        FROM r4".to_owned(),
            list_collections: "SELECT cursorPage, continuation, persistConnection, cursorId FROM documentdb_api.list_collections_cursor_first_page($1, $2)".to_owned(),
            validate: "SELECT documentdb_api.validate($1, $2)".to_owned(),
            find_and_modify: "SELECT * FROM documentdb_api.find_and_modify($1, $2, NULL)".to_owned(),
            distinct_query: "SELECT document FROM documentdb_api.distinct_query($1, $2)".to_owned(),
            count_query: "SELECT document FROM documentdb_api.count_query($1, $2)".to_owned(),
            coll_stats: "SELECT documentdb_api.coll_stats($1, $2, $3)".to_owned(),
            db_stats: "SELECT documentdb_api.db_stats($1, $2, $3)".to_owned(),
            current_op: "SELECT documentdb_api.current_op_command($1)".to_owned(),
            get_parameter: "SELECT documentdb_api.get_parameter($1, $2, $3)".to_owned(),
            compact: "SELECT documentdb_api.compact($1)".to_owned(),
            kill_op: "SELECT documentdb_api.kill_op($1)".to_owned(),

            // indexing.rs
            create_indexes_background: "SELECT * FROM documentdb_api.create_indexes_background($1, $2)".to_owned(),
            check_build_index_status: "SELECT * FROM documentdb_api_internal.check_build_index_status($1)".to_owned(),
            re_index: "CALL documentdb_api.re_index($1, $2)".to_owned(),
            drop_indexes: "CALL documentdb_api.drop_indexes($1, $2)".to_owned(),
            list_indexes_cursor_first_page: "SELECT cursorPage, continuation, persistConnection, cursorId FROM documentdb_api.list_indexes_cursor_first_page($1, $2)".to_owned(),

            // user.rs
            create_user: "SELECT documentdb_api.create_user($1)".to_owned(),
            drop_user: "SELECT documentdb_api.drop_user($1)".to_owned(),
            update_user: "SELECT documentdb_api.update_user($1)".to_owned(),
            users_info: "SELECT documentdb_api.users_info($1)".to_owned(),
            connection_status: "SELECT documentdb_api.connection_status($1)".to_owned(),

            // roles.rs
            create_role: "SELECT documentdb_api.create_role($1)".to_owned(),
            update_role: "SELECT documentdb_api.update_role($1)".to_owned(),
            drop_role: "SELECT documentdb_api.drop_role($1)".to_owned(),
            roles_info: "SELECT documentdb_api.roles_info($1)".to_owned(),

            // tests
            create_db_user: "CREATE ROLE \"{user}\" WITH LOGIN INHERIT PASSWORD '{pass}' IN ROLE documentdb_readonly_role; 
                             GRANT documentdb_admin_role TO {user} WITH ADMIN OPTION".to_owned(),

            // scan_types
            scan_types: vec![
                "DocumentDBApiScan".to_owned(),
                "DocumentDBApiQueryScan".to_owned(),
            ],

            ..Default::default()
        }
}
