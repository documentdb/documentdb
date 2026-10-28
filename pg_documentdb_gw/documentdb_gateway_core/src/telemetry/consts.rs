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
    pub const AUTHENTICATION_MECHANISM: &str = "docdb.authentication.mechanism";
    pub const AUTHENTICATION_OUTCOME: &str = "docdb.authentication.outcome";
    pub const TRANSACTION_END_OUTCOME: &str = "docdb.transaction.end.outcome";
    pub const CURSOR_END_REASON: &str = "docdb.cursor.end.reason";
    /// Backend connection pool role, such as `data`. Never a per-pool
    /// identifier.
    pub const BACKEND_CONNECTION_POOL_ROLE: &str = "docdb.backend.connection_pool.role";
    /// Backend connection state: `used` or `idle`.
    pub const DB_CLIENT_CONNECTION_STATE: &str = "db.client.connection.state";
}

// Explicit histogram bucket boundaries, named after the metric they apply to
pub mod histogram_bounds {
    /// Boundaries in seconds for `docdb.gateway.operation.duration`: fine
    /// resolution below one second, with upper buckets that separate slow
    /// requests from overflow.
    pub const OPERATION_DURATION: [f64; 14] = [
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 300.0,
    ];
}

// Metric names shared by instrumentation and exporter metadata
pub mod metric_names {
    pub const DOCUMENTS_DELETED: &str = "docdb.gateway.documents.deleted";
    pub const DOCUMENTS_INSERTED: &str = "docdb.gateway.documents.inserted";
    pub const DOCUMENTS_RETURNED: &str = "docdb.gateway.documents.returned";
    pub const DOCUMENTS_UPDATED: &str = "docdb.gateway.documents.updated";
    pub const AUTHENTICATION_ATTEMPTS: &str = "docdb.gateway.authentication.attempts";
    pub const OPERATION_DURATION: &str = "docdb.gateway.operation.duration";
    pub const OPERATIONS: &str = "docdb.gateway.operations";
    pub const REQUEST_SIZE_TOTAL: &str = "docdb.gateway.request.size.total";
    pub const RESPONSE_SIZE_TOTAL: &str = "docdb.gateway.response.size.total";
    pub const GATEWAY_STARTS: &str = "gateway.starts";
    pub const GATEWAY_STARTUP_DELAY_MS: &str = "gateway_startup_delay_ms";

    // Gateway resources
    /// Gauge of logical sessions currently tracked by the gateway.
    pub const SESSION_ACTIVE: &str = "docdb.gateway.session.active";
    /// Counter of logical sessions opened by the gateway.
    pub const SESSION_OPENED: &str = "docdb.gateway.session.opened";
    /// Counter of logical sessions closed normally.
    pub const SESSION_CLOSED: &str = "docdb.gateway.session.closed";
    /// Counter of logical sessions removed after their lifetime expired.
    pub const SESSION_EXPIRED: &str = "docdb.gateway.session.expired";

    /// Gauge of transactions currently held in the transaction store.
    pub const TRANSACTION_ACTIVE: &str = "docdb.gateway.transaction.active";
    /// Counter of transactions successfully started and stored.
    pub const TRANSACTION_STARTED: &str = "docdb.gateway.transaction.started";
    /// Counter of ended transactions, partitioned by `docdb.transaction.end.outcome`.
    /// Supported outcomes are `committed`, `aborted`, and `expired`.
    pub const TRANSACTION_ENDED: &str = "docdb.gateway.transaction.ended";

    /// Gauge of cursors currently held in the cursor store.
    pub const CURSOR_ACTIVE: &str = "docdb.gateway.cursor.active";
    /// Counter of logical cursors opened from an initial query continuation.
    pub const CURSOR_OPENED: &str = "docdb.gateway.cursor.opened";
    /// Counter of ended cursors, partitioned by `docdb.cursor.end.reason`.
    /// Supported reasons are `exhausted`, `killed`, `invalidated`, and `expired`.
    pub const CURSOR_ENDED: &str = "docdb.gateway.cursor.ended";

    // Backend connection pools, partitioned by `docdb.backend.connection_pool.role`
    /// Gauge of open backend connections, partitioned by
    /// `db.client.connection.state`.
    pub const BACKEND_CONNECTION_POOL_USAGE: &str = "docdb.backend.connection_pool.usage";
    /// Gauge of the maximum backend connections the pools of a role allow.
    pub const BACKEND_CONNECTION_POOL_LIMIT: &str = "docdb.backend.connection_pool.limit";
    /// Gauge of requests waiting for a backend connection.
    pub const BACKEND_CONNECTION_POOL_WAIT_ACTIVE: &str =
        "docdb.backend.connection_pool.wait.active";
    /// Counter of backend connection acquisitions that timed out.
    pub const BACKEND_CONNECTION_POOL_TIMEOUT_COUNT: &str =
        "docdb.backend.connection_pool.timeout.count";
    /// Counter of backend connection creation attempts. Failed attempts carry
    /// `error.type`: `auth`, `connection_limit`, `network`, or `other`.
    pub const BACKEND_CONNECTION_CREATE_COUNT: &str = "docdb.backend.connection.create.count";
}
