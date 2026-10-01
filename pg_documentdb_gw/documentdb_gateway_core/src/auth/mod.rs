/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod command;
mod manager;
mod state;

pub mod scram;

pub use command::handle_authentication;
pub use manager::{
    AuthenticationFailed, AuthenticationHandler, AuthenticationManager, AuthenticationProvider,
    AuthenticationResult, AuthenticationSuccess,
};
pub use scram::get_user_oid;
pub use state::UserAuthState;

#[cfg(test)]
mod tests;
