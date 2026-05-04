/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/cursor/gateway_cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::RawDocumentBuf;
use tokio::time::{Duration, Instant};

use crate::{
    context::CursorId, context::SessionId, context::TransactionNumber,
    postgres::conn_mgmt::Connection,
};

#[derive(Debug)]
pub struct Cursor {
    pub continuation: RawDocumentBuf,
    pub cursor_id: CursorId,
}

#[derive(Debug)]
pub struct CursorStoreEntry {
    pub conn: Option<Arc<Connection>>,
    pub cursor: Cursor,
    pub db: String,
    pub collection: String,
    pub timestamp: Instant,
    pub cursor_timeout: Duration,
    pub session_id: Option<SessionId>,
    pub transaction_number: Option<TransactionNumber>,
}
