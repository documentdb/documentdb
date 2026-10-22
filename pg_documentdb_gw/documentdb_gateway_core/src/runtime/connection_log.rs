// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//! Correlates connection termination events across gateway runtimes.

use openssl::ssl::SslRef;
use uuid::Uuid;

use crate::{error::Result, service::TlsProvider};

/// Emits one close event, including when the connection task is cancelled or unwinds.
#[derive(Debug)]
pub(super) struct ConnectionLog {
    connection_id: Uuid,
    client_ip: String,
    transport: &'static str,
    host_name_from_sni: String,
    close_reason: &'static str,
}

impl ConnectionLog {
    /// Starts termination tracking for one connection task.
    pub(super) const fn new(
        connection_id: Uuid,
        client_ip: String,
        transport: &'static str,
    ) -> Self {
        Self {
            connection_id,
            client_ip,
            transport,
            host_name_from_sni: String::new(),
            close_reason: "cancelled",
        }
    }

    /// Retains the escaped SNI while the TLS stream is owned by the serving loop.
    pub(super) fn record_tls(&mut self, ssl: &SslRef) {
        self.host_name_from_sni = TlsProvider::sni_host_name_for_logging(ssl).to_string();
    }

    /// Records the serving outcome and logs terminal errors with connection context.
    pub(super) fn finish(&mut self, result: &Result<()>) {
        match result {
            Ok(()) => self.close_reason = "completed",
            Err(error) => {
                self.close_reason = "error";
                tracing::error!(
                    activity_id = %self.connection_id,
                    connection_id = %self.connection_id,
                    client_ip = self.client_ip,
                    transport = self.transport,
                    error = ?error,
                    "Gateway runtime connection failed: {error:?}."
                );
            }
        }
    }
}

impl Drop for ConnectionLog {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.close_reason = "panicked";
            tracing::error!(
                activity_id = %self.connection_id,
                connection_id = %self.connection_id,
                client_ip = self.client_ip,
                transport = self.transport,
                "Gateway runtime connection task panicked."
            );
        }
        tracing::info!(
            activity_id = %self.connection_id,
            connection_id = %self.connection_id,
            client_ip = self.client_ip,
            transport = self.transport,
            host_name_from_sni = self.host_name_from_sni,
            close_reason = self.close_reason,
            "Socket: Closing connection - Connection Id {}, client IP {}, HostNameFromSni {}",
            self.connection_id,
            self.client_ip,
            self.host_name_from_sni,
        );
    }
}

#[cfg(test)]
#[path = "connection_log_tests.rs"]
mod tests;
