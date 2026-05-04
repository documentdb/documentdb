/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/security/principal.rs
 *
 *-------------------------------------------------------------------------
 */

/// Represents the security context of the user on whose behalf the code is
/// running.
///
/// A `Principal` pairs a human-readable role name with the `PostgreSQL` OID
/// that backs it. It is produced during authentication and threaded through
/// downstream components (sessions, command dispatch, audit logging) that
/// need to know who is performing an operation.
///
/// Instances are cheap to clone and are usable as keys in hashed
/// collections.
///
/// # Examples
///
/// ```
/// use documentdb_gateway_core::security::principal::Principal;
///
/// let p = Principal::new("bob", 1);
/// assert_eq!(p.name(), "bob");
/// assert_eq!(p.oid(), 1);
/// ```
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Principal {
    name: String,
    oid: u32,
}

impl Principal {
    /// Creates a new [`Principal`] from a role name and its `PostgreSQL` OID.
    #[must_use]
    pub fn new(name: impl Into<String>, oid: u32) -> Self {
        Self {
            name: name.into(),
            oid,
        }
    }

    /// Returns the role name associated with this principal.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Returns the `PostgreSQL` OID, Object Identifier, associated with this principal.
    #[must_use]
    pub const fn oid(&self) -> u32 {
        self.oid
    }
}

/// Convenience constructor for [`Principal`].
///
/// # Examples
///
/// ```
/// use documentdb_gateway_core::{principal, security::principal::Principal};
///
/// let p = principal!("bob", 1);
/// assert_eq!(p.name(), "bob");
/// assert_eq!(p.oid(), 1);
/// ```
#[macro_export]
macro_rules! principal {
    ($name:expr, $oid:expr $(,)?) => {
        $crate::security::principal::Principal::new($name, $oid)
    };
}

#[cfg(test)]
mod tests {
    use crate::security::principal::Principal;

    #[test]
    pub fn principal_is_equal() {
        let principal_a = Principal::new("bob", 1);
        let principal_b = Principal::new("bob", 1);

        assert_eq!(principal_a, principal_b);
    }

    #[test]
    pub fn principal_macro() {
        let principal_a = principal!("bob", 1);
        let principal_b = Principal::new("bob", 1);

        assert_eq!(principal_a, principal_b);
    }
}
