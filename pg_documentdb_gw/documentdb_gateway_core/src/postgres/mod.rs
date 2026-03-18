/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/mod.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod conn_mgmt;
mod data_client;
pub(crate) mod document;
mod documentdb_data_client;
mod query_catalog;
mod scoped_transaction;
mod transaction;

pub use data_client::PgDataClient;
pub use document::PgDocument;
pub use documentdb_data_client::{remap_error, DocumentDBDataClient};
pub use query_catalog::{create_query_catalog, QueryCatalog};
pub use scoped_transaction::ScopedTransaction;
pub use transaction::Transaction;
