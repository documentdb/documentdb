/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/mod.rs
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
// imports (AuthState, AuthKind, process, get_user_oid) keep working.
pub use crate::auth_legacy::{get_user_oid, process, AuthKind, AuthState, ScramFirstState};
