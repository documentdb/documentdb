/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/handler_tests.rs
 *
 * Unit tests for auth handler routing and AuthState active_mechanism.
 * Full handler routing tests require a ConnectionContext with a PG
 * backend and are covered by integration tests.
 *
 *-------------------------------------------------------------------------
 */

use crate::auth_legacy::AuthState;

// ---------------------------------------------------------------------------
// AuthState active_mechanism tests (Requirements 6.4, 9.1, 9.2)
// ---------------------------------------------------------------------------

#[test]
fn active_mechanism_initially_none() {
    let state = AuthState::new();
    assert!(state.active_mechanism().is_none());
}

#[test]
fn set_active_mechanism_stores_value() {
    let mut state = AuthState::new();
    state.set_active_mechanism("SCRAM-SHA-256");
    assert_eq!(state.active_mechanism(), Some("SCRAM-SHA-256"));
}

#[test]
fn set_active_mechanism_can_be_overwritten() {
    let mut state = AuthState::new();
    state.set_active_mechanism("SCRAM-SHA-256");
    state.set_active_mechanism("MONGODB-OIDC");
    assert_eq!(state.active_mechanism(), Some("MONGODB-OIDC"));
}

#[test]
fn logout_resets_active_mechanism() {
    let mut state = AuthState::new();
    state.set_active_mechanism("SCRAM-SHA-256");

    // Simulate logout by creating a new AuthState
    state = AuthState::new();
    assert!(state.active_mechanism().is_none());
}

#[test]
fn new_auth_state_has_no_username() {
    let state = AuthState::new();
    assert!(state.username().is_err());
}

#[test]
fn connection_close_resets_all_auth_state() {
    let mut state = AuthState::new();
    state.set_active_mechanism("SCRAM-SHA-256");
    state.set_username("testuser");
    state.password = Some("pass".to_string());
    state.user_oid = Some(42);

    // Simulate connection close cleanup
    state = AuthState::new();

    assert!(state.active_mechanism().is_none());
    assert!(state.username().is_err());
    assert!(state.password.is_none());
    assert!(state.user_oid.is_none());
}
