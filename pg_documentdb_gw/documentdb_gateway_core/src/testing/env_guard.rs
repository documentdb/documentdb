/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/env_guard.rs
 *
 * Shared testing helpers for managing environment variables in tests.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    collections::HashSet,
    env,
    sync::{LazyLock, Mutex, MutexGuard},
};

static ENV_GUARD_MUTEX: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

/// Helper to temporarily set env vars, restoring on drop.
pub struct EnvGuard {
    _lock: MutexGuard<'static, ()>,
    originals: Vec<(String, Option<String>)>,
}

impl EnvGuard {
    pub fn set(key: &str, value: &str) -> Self {
        Self::set_many([(key, value)])
    }

    pub fn set_many<'a, I>(overrides: I) -> Self
    where
        I: IntoIterator<Item = (&'a str, &'a str)>,
    {
        let lock = ENV_GUARD_MUTEX.lock().expect("env guard mutex poisoned");
        let mut originals = Vec::new();
        let mut seen_keys = HashSet::new();

        for (key, value) in overrides {
            if seen_keys.insert(key.to_owned()) {
                originals.push((key.to_owned(), env::var(key).ok()));
            }
            env::set_var(key, value);
        }

        Self {
            _lock: lock,
            originals,
        }
    }

    pub fn remove(key: &str) -> Self {
        let lock = ENV_GUARD_MUTEX.lock().expect("env guard mutex poisoned");
        let original = env::var(key).ok();
        env::remove_var(key);
        Self {
            _lock: lock,
            originals: vec![(key.to_owned(), original)],
        }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, original) in self.originals.drain(..) {
            match original {
                Some(val) => env::set_var(&key, val),
                None => env::remove_var(&key),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_restores_missing_variable_on_drop() {
        let key = "DOCUMENTDB_TEST_ENVGUARD_SET_RESTORE_MISSING";
        env::remove_var(key);

        {
            let _guard = EnvGuard::set(key, "temporary-value");
            assert_eq!(env::var(key).ok().as_deref(), Some("temporary-value"));
        }

        assert_eq!(env::var(key).ok(), None);
    }

    #[test]
    fn set_restores_original_variable_on_drop() {
        let key = "DOCUMENTDB_TEST_ENVGUARD_SET_RESTORE_ORIGINAL";
        env::set_var(key, "original-value");

        {
            let _guard = EnvGuard::set(key, "temporary-value");
            assert_eq!(env::var(key).ok().as_deref(), Some("temporary-value"));
        }

        assert_eq!(env::var(key).ok().as_deref(), Some("original-value"));
        env::remove_var(key);
    }

    #[test]
    fn set_many_applies_all_overrides_and_restores_originals() {
        let existing_key = "DOCUMENTDB_TEST_ENVGUARD_SET_MANY_EXISTING";
        let missing_key = "DOCUMENTDB_TEST_ENVGUARD_SET_MANY_MISSING";
        env::set_var(existing_key, "original-value");
        env::remove_var(missing_key);

        {
            let _guard = EnvGuard::set_many([
                (existing_key, "temporary-existing"),
                (missing_key, "temporary-missing"),
            ]);
            assert_eq!(
                env::var(existing_key).ok().as_deref(),
                Some("temporary-existing")
            );
            assert_eq!(
                env::var(missing_key).ok().as_deref(),
                Some("temporary-missing")
            );
        }

        assert_eq!(
            env::var(existing_key).ok().as_deref(),
            Some("original-value")
        );
        assert_eq!(env::var(missing_key).ok(), None);
        env::remove_var(existing_key);
    }

    #[test]
    fn set_many_restores_original_when_same_key_is_overridden_twice() {
        let key = "DOCUMENTDB_TEST_ENVGUARD_SET_MANY_DUPLICATE";
        env::set_var(key, "original-value");

        {
            let _guard = EnvGuard::set_many([(key, "first-override"), (key, "second-override")]);
            assert_eq!(env::var(key).ok().as_deref(), Some("second-override"));
        }

        assert_eq!(env::var(key).ok().as_deref(), Some("original-value"));
        env::remove_var(key);
    }

    #[test]
    fn remove_restores_missing_variable_on_drop() {
        let key = "DOCUMENTDB_TEST_ENVGUARD_REMOVE_RESTORE_MISSING";
        env::remove_var(key);

        {
            let _guard = EnvGuard::remove(key);
            assert_eq!(env::var(key).ok(), None);
        }

        assert_eq!(env::var(key).ok(), None);
    }

    #[test]
    fn remove_restores_original_variable_on_drop() {
        let key = "DOCUMENTDB_TEST_ENVGUARD_REMOVE_RESTORE_ORIGINAL";
        env::set_var(key, "original-value");

        {
            let _guard = EnvGuard::remove(key);
            assert_eq!(env::var(key).ok(), None);
        }

        assert_eq!(env::var(key).ok().as_deref(), Some("original-value"));
        env::remove_var(key);
    }
}
