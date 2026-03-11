/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/auth/mod.rs
 *
 * Pluggable authentication module. Declares submodules for the trait-based,
 * registry-driven authentication architecture and re-exports legacy types
 * so that existing code continues to compile unchanged.
 *
 *-------------------------------------------------------------------------
 */

pub mod handler;
pub mod oidc_provider;
pub mod provider;
pub mod registry;
pub mod scram_provider;

// Re-export the core pluggable auth types for convenient access.
pub use provider::{AuthProvider, ProviderConfig};
pub use registry::AuthProviderRegistry;

// Re-export legacy types and functions so that existing `crate::auth::*`
// imports keep working.
pub use crate::auth_legacy::{process, AuthKind, AuthState, ScramFirstState};

// ---------------------------------------------------------------------------
// Shared auth utilities
// ---------------------------------------------------------------------------

use tokio_postgres::types::Type;

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, Result},
    requests::request_tracker::RequestTracker,
};

/// Look up the PostgreSQL role OID for a given username.
/// Used by both ScramProvider and OidcProvider after successful authentication.
pub async fn get_user_oid(connection_context: &ConnectionContext, username: &str) -> Result<u32> {
    let user_oid_rows = connection_context
        .service_context
        .connection_pool_manager()
        .authentication_connection()
        .await?
        .query(
            "SELECT oid from pg_roles WHERE rolname = $1",
            &[Type::TEXT],
            &[&username],
            None,
            &RequestTracker::new(),
        )
        .await?;

    let user_oid = user_oid_rows
        .first()
        .ok_or(DocumentDBError::pg_response_empty())?
        .try_get::<_, tokio_postgres::types::Oid>(0)?;

    Ok(user_oid)
}
