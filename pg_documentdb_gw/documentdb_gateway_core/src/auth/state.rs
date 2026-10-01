/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/state.rs
 *
 *-------------------------------------------------------------------------
 */

use serde_json::Value;

use crate::{
    error::{DocumentDBError, Result},
    postgres::conn_mgmt::PgPoolSettings,
    security::principal::Principal,
    time::EpochClock,
};

#[derive(Debug, Default, Eq, PartialEq)]
enum AuthStatus {
    #[default]
    NotAuthenticated,
    InProgress,
    Authenticated,
    Expired,
}

#[derive(Debug, Default)]
pub struct UserAuthState {
    scheme: Option<String>,
    status: AuthStatus,
    principal: Option<Principal>,
    reauthentication_principal: Option<Principal>,
    metadata: Option<Value>,
    expires_at: Option<u64>,
    data_pool_settings: Option<PgPoolSettings>,
}

impl UserAuthState {
    /// Creates state for an authentication conversation in progress under
    /// `scheme`, retaining a previously verified principal for reauthentication.
    #[must_use]
    pub(crate) fn begin(scheme: &str, reauthentication_principal: Option<Principal>) -> Self {
        Self {
            scheme: Some(scheme.to_owned()),
            status: AuthStatus::InProgress,
            principal: None,
            reauthentication_principal,
            metadata: None,
            expires_at: None,
            data_pool_settings: None,
        }
    }

    /// Creates state for a connection that completed authentication under
    /// `scheme` as `principal`.
    #[must_use]
    pub fn authenticated(
        scheme: &str,
        principal: Principal,
        metadata: Option<Value>,
        expires_at: Option<u64>,
    ) -> Self {
        Self {
            scheme: Some(scheme.to_owned()),
            status: AuthStatus::Authenticated,
            principal: Some(principal),
            reauthentication_principal: None,
            metadata,
            expires_at,
            data_pool_settings: None,
        }
    }

    #[must_use]
    pub fn is_authenticated(&self) -> bool {
        self.status == AuthStatus::Authenticated
            && self
                .expires_at
                .is_none_or(|expires_at| EpochClock::almost_now_timestamp() < expires_at)
    }

    #[must_use]
    pub fn scheme(&self) -> Option<&str> {
        self.scheme.as_deref()
    }

    /// Returns the authenticated principal.
    ///
    /// # Errors
    ///
    /// Returns an error when authentication has not established a principal.
    pub fn principal(&self) -> Result<&Principal> {
        self.principal.as_ref().ok_or_else(|| {
            DocumentDBError::not_authenticated("User is not authenticated".to_owned())
        })
    }

    #[must_use]
    pub fn is_expired(&self) -> bool {
        self.status == AuthStatus::Expired
    }

    #[must_use]
    pub fn metadata(&self, scheme: &str) -> Option<&Value> {
        (self.scheme() == Some(scheme))
            .then_some(self.metadata.as_ref())
            .flatten()
    }

    /// Stores conversation state for the mechanism that owns the current
    /// authentication attempt.
    ///
    /// # Errors
    ///
    /// Returns an error if another mechanism attempts to store state.
    pub fn set_metadata(&mut self, scheme: &str, metadata: Value) -> Result<()> {
        if self.scheme() != Some(scheme) || self.status != AuthStatus::InProgress {
            return Err(DocumentDBError::internal_error(
                "Authentication mechanism attempted to access another mechanism's state".to_owned(),
            ));
        }

        self.metadata = Some(metadata);
        Ok(())
    }

    pub(crate) const fn set_data_pool_settings(&mut self, settings: PgPoolSettings) {
        self.data_pool_settings = Some(settings);
    }

    pub(crate) fn data_pool_settings(&self) -> Result<PgPoolSettings> {
        self.data_pool_settings
            .ok_or_else(|| DocumentDBError::internal_error("Data pool settings missing".to_owned()))
    }

    #[must_use]
    pub(crate) const fn reauthentication_principal(&self) -> Option<&Principal> {
        match self.status {
            AuthStatus::Expired => self.principal.as_ref(),
            AuthStatus::NotAuthenticated | AuthStatus::InProgress => {
                self.reauthentication_principal.as_ref()
            }
            AuthStatus::Authenticated => None,
        }
    }

    pub(crate) fn validate_reauthentication_principal(&self, principal: &Principal) -> Result<()> {
        if self
            .reauthentication_principal
            .as_ref()
            .is_some_and(|previous_principal| previous_principal != principal)
        {
            return Err(DocumentDBError::authentication_failed(
                "Authentication Failed".to_owned(),
            ));
        }

        Ok(())
    }

    pub(crate) fn clear_failed_attempt(&mut self) {
        let reauthentication_principal = self.reauthentication_principal().cloned();
        *self = reauthentication_principal.map_or_else(Self::default, |principal| Self {
            status: AuthStatus::Expired,
            principal: Some(principal),
            ..Self::default()
        });
    }

    pub(crate) fn update_expiration_status(&mut self) -> bool {
        if self.status != AuthStatus::Authenticated {
            return false;
        }

        if self
            .expires_at
            .is_some_and(|expires_at| expires_at <= EpochClock::almost_now_timestamp())
        {
            self.status = AuthStatus::Expired;
            self.metadata = None;
            self.data_pool_settings = None;
            return true;
        }

        false
    }
}
