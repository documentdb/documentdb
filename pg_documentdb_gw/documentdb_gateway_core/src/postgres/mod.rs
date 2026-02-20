/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/mod.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod conn_mgmt;
mod data_client;
mod document;
mod documentdb_data_client;
mod query_catalog;
mod transaction;

pub use data_client::PgDataClient;
pub use document::PgDocument;
pub use documentdb_data_client::DocumentDBDataClient;
pub use query_catalog::{create_query_catalog, QueryCatalog};
pub use transaction::Transaction;
