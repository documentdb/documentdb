/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/connection.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    hash::{DefaultHasher, Hash, Hasher},
    sync::Arc,
};

use bson::RawDocumentBuf;
use openssl::ssl::SslRef;
use tokio::time::{Duration, Instant};
use uuid::{Builder, Uuid};

use crate::{
    auth::AuthState,
    configuration::DynamicConfiguration,
    context::{
        session::SessionKey, Cursor, CursorId, CursorKey, CursorRef, CursorStoreEntry,
        LogicalSessionId, ServiceContext, TransactionNumber,
    },
    error::Result,
    postgres::conn_mgmt::{Connection, PgPoolSettings},
    security::principal::Principal,
    service::TlsProvider,
    telemetry::TelemetryProvider,
};

#[derive(Debug)]
pub struct ConnectionContext {
    pub start_time: Instant,
    pub connection_id: Uuid,
    pub service_context: Arc<ServiceContext>,
    pub auth_state: AuthState,
    pub requires_response: bool,
    pub client_information: Option<RawDocumentBuf>,
    pub transaction: Option<(LogicalSessionId, TransactionNumber)>,
    pub telemetry_provider: Option<Box<dyn TelemetryProvider>>,
    pub ip_address: String,
    pub cipher_type: i32,
    pub ssl_protocol: String,
    transport_protocol: String,
    connection_id_hash: i32,
    /// Thumbprint of the certificate captured on the TLS handshake; `None` for plaintext.
    server_certificate_thumbprint: Option<String>,
    /// Time of the last rotation check, used to rate-limit checks.
    last_cert_rotation_check: Option<Instant>,
    /// Set once a graceful closure has been sent so the loop closes after the response.
    close_after_response: bool,
}

impl ConnectionContext {
    #[must_use]
    pub fn new(
        service_context: ServiceContext,
        telemetry_provider: Option<Box<dyn TelemetryProvider>>,
        ip_address: String,
        tls_config: Option<&SslRef>,
        connection_id: Uuid,
        transport_protocol: String,
    ) -> Self {
        let cipher_type = if let Some(tls) = tls_config {
            service_context
                .tls_provider()
                .ciphersuite_to_i32(tls.current_cipher())
        } else {
            0
        };

        let ssl_protocol = tls_config
            .map(|tls| tls.version_str().to_owned())
            .unwrap_or_default();

        // Capture the handshake certificate (TLS only) so rotation detection
        // compares against the cert this connection actually negotiated.
        let server_certificate_thumbprint = tls_config
            .and_then(SslRef::certificate)
            .and_then(TlsProvider::certificate_thumbprint);

        Self {
            start_time: Instant::now(),
            connection_id,
            service_context: Arc::new(service_context),
            auth_state: AuthState::new(),
            requires_response: true,
            client_information: None,
            transaction: None,
            telemetry_provider,
            ip_address,
            cipher_type,
            ssl_protocol,
            transport_protocol,
            connection_id_hash: Self::get_uuid_hash(connection_id),
            server_certificate_thumbprint,
            last_cert_rotation_check: None,
            close_after_response: false,
        }
    }

    #[must_use]
    pub fn get_cursor(&self, id: i64, caller: &Principal) -> Option<CursorStoreEntry> {
        let key = CursorKey::new(id.into(), caller.clone());

        // If there is a transaction, validate that the transaction owns the cursor before using it
        if let Some((lsid, _)) = self.transaction.as_ref() {
            let transaction_store = self.service_context.transaction_store();
            let session_key = SessionKey::new(lsid.clone(), caller.clone());
            if let Some(entry) = transaction_store.transactions.get(&session_key) {
                let (_, transaction) = entry.value();
                if !transaction.contains_cursor(id.into()) {
                    return None;
                }
            }
        }

        self.service_context.cursor_store().get_cursor(&key)
    }

    #[must_use]
    pub fn get_cursor_ref(&self, id: i64, caller: &Principal) -> Option<CursorRef> {
        let key = CursorKey::new(id.into(), caller.clone());
        self.service_context.cursor_store().get_cursor_ref(&key)
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "cursor creation requires multiple parameters"
    )]
    pub fn add_cursor(
        &self,
        conn: Option<Arc<Connection>>,
        cursor: Cursor,
        db: &str,
        collection: &str,
        cursor_timeout: Duration,
        lsid: Option<LogicalSessionId>,
        transaction_number: Option<TransactionNumber>,
        caller: &Principal,
    ) {
        let cursor_id = cursor.cursor_id;

        // If there is a transaction, add it to the tracked cursors
        if let Some((lsid, _)) = self.transaction.as_ref() {
            let transaction_store = self.service_context.transaction_store();
            let session_key: crate::context::StoreKey<LogicalSessionId> =
                SessionKey::new(lsid.clone(), caller.clone());
            if let Some(entry) = transaction_store.transactions.get(&session_key) {
                let (_, transaction) = entry.value();
                transaction.add_cursor(cursor_id);
            }
        }

        self.store_cursor(
            conn,
            cursor,
            db,
            collection,
            cursor_timeout,
            lsid,
            transaction_number,
            caller,
        );
        self.service_context
            .session_manager()
            .metrics()
            .cursor_opened();
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "cursor reinsertion requires the stored cursor state"
    )]
    pub fn return_cursor(
        &self,
        conn: Option<Arc<Connection>>,
        cursor: Cursor,
        db: &str,
        collection: &str,
        cursor_timeout: Duration,
        lsid: Option<LogicalSessionId>,
        transaction_number: Option<TransactionNumber>,
        caller: &Principal,
    ) {
        self.store_cursor(
            conn,
            cursor,
            db,
            collection,
            cursor_timeout,
            lsid,
            transaction_number,
            caller,
        );
    }

    pub fn close_cursor(
        &self,
        lsid: Option<&LogicalSessionId>,
        transaction_number: Option<TransactionNumber>,
        cursor_id: CursorId,
        caller: &Principal,
    ) {
        if let (Some(lsid), Some(transaction_number)) = (lsid, transaction_number) {
            let session_key = SessionKey::new(lsid.clone(), caller.clone());
            if let Some(entry) = self
                .service_context
                .transaction_store()
                .transactions
                .get(&session_key)
            {
                let (_, transaction) = entry.value();
                if transaction.transaction_number() == transaction_number {
                    transaction.remove_cursor(cursor_id);
                }
            }
        }

        self.service_context
            .session_manager()
            .metrics()
            .cursor_exhausted();
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "cursor storage requires the complete cursor state"
    )]
    fn store_cursor(
        &self,
        conn: Option<Arc<Connection>>,
        cursor: Cursor,
        db: &str,
        collection: &str,
        cursor_timeout: Duration,
        lsid: Option<LogicalSessionId>,
        transaction_number: Option<TransactionNumber>,
        caller: &Principal,
    ) {
        let key = CursorKey::new(cursor.cursor_id, caller.clone());
        let value = CursorStoreEntry {
            conn,
            cursor,
            db: db.to_owned(),
            collection: collection.to_owned(),
            timestamp: Instant::now(),
            cursor_timeout,
            lsid,
            transaction_number,
        };

        self.service_context.cursor_store().add_cursor(key, value);
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn allocate_data_pool(&mut self, password: &str) -> Result<()> {
        let username = self.auth_state.username()?;
        let settings = PgPoolSettings::from_configuration(
            self.service_context.dynamic_configuration().as_ref(),
        );

        self.service_context
            .connection_pool_manager()
            .allocate_data_pool_with_settings(username, password, settings)?;
        self.auth_state.set_data_pool_settings(settings);
        Ok(())
    }

    #[must_use]
    pub fn dynamic_configuration(&self) -> Arc<dyn DynamicConfiguration> {
        self.service_context.dynamic_configuration()
    }

    /// Returns `true` when the server certificate has rotated since this
    /// connection was established, flagging it to close after its response. The
    /// check is rate-limited to once per `connectionGracefulClosureIntervalSec`.
    #[must_use]
    pub fn cert_rotation_requires_graceful_closure(&mut self) -> bool {
        let configuration = self.dynamic_configuration();
        if !configuration.enable_graceful_closure_on_cert_rotation() {
            return false;
        }

        let Some(established_thumbprint) = self.server_certificate_thumbprint.clone() else {
            return false;
        };

        let interval =
            Duration::from_secs(configuration.connection_graceful_closure_interval_sec());
        let now = Instant::now();
        if let Some(last_check) = self.last_cert_rotation_check {
            if now.duration_since(last_check) < interval {
                return false;
            }
        }
        self.last_cert_rotation_check = Some(now);

        let current_thumbprint = self
            .service_context
            .tls_provider()
            .current_certificate_thumbprint();

        match current_thumbprint {
            Some(current) if current != established_thumbprint => {
                tracing::warn!(
                    connection_id = %self.connection_id,
                    "Graceful closure needed because of certificate rotation."
                );
                self.close_after_response = true;
                true
            }
            _ => false,
        }
    }

    /// Returns `true` when the connection loop should close after this response.
    #[must_use]
    pub const fn close_after_response(&self) -> bool {
        self.close_after_response
    }

    /// Records the certificate thumbprint captured on this connection's TLS
    /// handshake. Used by the v2 runtime, which builds the context after the
    /// handshake completes.
    pub fn set_server_certificate_thumbprint(&mut self, thumbprint: Option<String>) {
        self.server_certificate_thumbprint = thumbprint;
    }

    #[cfg(test)]
    pub fn set_server_certificate_thumbprint_for_test(&mut self, thumbprint: Option<String>) {
        self.server_certificate_thumbprint = thumbprint;
        self.last_cert_rotation_check = None;
    }

    /// Generates a per-request activity ID by embedding the given `request_id`
    /// into the caller’s connection UUID and returning it as a hyphenated string.
    ///
    /// The function copies the current `connection_id` (a 16-byte UUID), overwrites
    /// bytes 12..16 (the final 4 bytes) with `request_id.to_be_bytes()`
    /// to preserve UUID version/variant bits, then returns the resulting UUID’s
    /// canonical (lowercase, hyphenated) string form.
    ///
    /// # Parameters
    /// - `request_id`: 32-bit identifier to embed (stored big-endian in bytes 12–15).
    ///
    /// # Returns
    /// The activity UUID itself. Use `hyphenated().encode_lower()` for string form.
    #[must_use]
    pub fn generate_request_activity_id(&self, request_id: i32) -> Uuid {
        let mut activity_id_bytes = *self.connection_id.as_bytes();
        activity_id_bytes[12..].copy_from_slice(&request_id.to_be_bytes());
        Builder::from_bytes(activity_id_bytes).into_uuid()
    }

    #[must_use]
    pub fn transport_protocol(&self) -> &str {
        &self.transport_protocol
    }

    /// Returns `true` if request metrics are enabled for this connection.
    /// This is a temporary measure until we have a more comprehensive metrics system in place.
    #[must_use]
    pub fn request_metrics_enabled(&self) -> bool {
        self.service_context.request_metrics_enabled()
    }

    #[must_use]
    pub const fn get_connection_id_hash(&self) -> i32 {
        self.connection_id_hash
    }

    /// Returns a non-negative 32-bit hash for `self.connection_id`.
    ///
    /// Implementation details:
    /// - Hashes `connection_id` with `DefaultHasher` to a 64-bit value.
    /// - Folds to 32 bits by `XORing` high and low halves.
    /// - Masks off the sign bit (`& 0x7fff_ffff`) so the result fits in `0..=i31::MAX`.
    fn get_uuid_hash(connection_id: Uuid) -> i32 {
        let mut hasher = DefaultHasher::new();
        connection_id.hash(&mut hasher);
        let finished_hash = hasher.finish();
        ((finished_hash ^ (finished_hash >> 32)) & 0x7fff_ffff) as i32
    }
}
