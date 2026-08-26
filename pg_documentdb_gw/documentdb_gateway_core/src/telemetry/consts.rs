/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/consts.rs
 *
 *-------------------------------------------------------------------------
 */

// Labels used for metrics and tracing
pub mod labels {
    pub const DB_SYSTEM_NAME: &str = "db.system.name"; // Eg. generic.documentdb - `{provider}.documentdb`
    pub const DB_COLLECTION_NAME: &str = "db.collection.name";
    pub const DB_NAMESPACE: &str = "db.namespace";
    pub const DB_OPERATION_NAME: &str = "db.operation.name";
    pub const DB_OPERATION_PHASE: &str = "db.operation.phase";
    pub const ERROR_TYPE: &str = "error.type";
}

// Metric names shared by instrumentation and exporter metadata
pub mod metric_names {
    pub const DB_CLIENT_DOCUMENTS_DELETED: &str = "db.client.documents.deleted";
    pub const DB_CLIENT_DOCUMENTS_INSERTED: &str = "db.client.documents.inserted";
    pub const DB_CLIENT_DOCUMENTS_RETURNED: &str = "db.client.documents.returned";
    pub const DB_CLIENT_DOCUMENTS_UPDATED: &str = "db.client.documents.updated";
    pub const DB_CLIENT_OPERATION_DURATION: &str = "db.client.operation.duration";
    pub const DB_CLIENT_OPERATIONS: &str = "db.client.operations";
    pub const DB_CLIENT_REQUEST_SIZE_TOTAL: &str = "db.client.request.size.total";
    pub const DB_CLIENT_RESPONSE_SIZE_TOTAL: &str = "db.client.response.size.total";
    pub const GATEWAY_STARTS: &str = "gateway.starts";
    pub const GATEWAY_STARTUP_DELAY_MS: &str = "gateway_startup_delay_ms";
}
