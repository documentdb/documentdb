/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/sql_commenter.rs
 *
 * SQLCommenter-style trace correlation for data-path queries.
 *
 *-------------------------------------------------------------------------
 */

//! Provider-neutral hook for adding comments to outbound `PostgreSQL` queries.

use std::{fmt::Debug, sync::OnceLock};

/// Provider hook that builds a comment for the currently executing query.
pub trait SqlCommenterHook: Send + Sync + Debug {
    /// Returns a complete SQL block comment, or `None` when this query should
    /// use the normal prepared-statement path.
    fn current_comment(&self) -> Option<String>;
}

static SQL_COMMENTER_HOOK: OnceLock<&'static dyn SqlCommenterHook> = OnceLock::new();

/// Installs the process-wide SQL commenter hook.
///
/// Returns `false` when another telemetry provider already installed one.
#[must_use]
pub fn install_sql_commenter_hook(hook: &'static dyn SqlCommenterHook) -> bool {
    SQL_COMMENTER_HOOK.set(hook).is_ok()
}

pub(crate) fn current_comment() -> Option<String> {
    SQL_COMMENTER_HOOK
        .get()
        .and_then(|hook| hook.current_comment())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct TestHook(&'static str);

    impl SqlCommenterHook for TestHook {
        fn current_comment(&self) -> Option<String> {
            Some(self.0.to_owned())
        }
    }

    static FIRST_HOOK: TestHook = TestHook("/*provider='first'*/");
    static SECOND_HOOK: TestHook = TestHook("/*provider='second'*/");

    #[test]
    fn installs_one_provider_neutral_hook() {
        assert!(install_sql_commenter_hook(&FIRST_HOOK));
        assert_eq!(current_comment().as_deref(), Some("/*provider='first'*/"));
        assert!(!install_sql_commenter_hook(&SECOND_HOOK));
        assert_eq!(current_comment().as_deref(), Some("/*provider='first'*/"));
    }
}
