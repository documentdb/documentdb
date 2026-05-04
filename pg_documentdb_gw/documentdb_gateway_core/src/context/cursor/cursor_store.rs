/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/cursor/cursor_store.rs
 *
 *-------------------------------------------------------------------------
 */

use dashmap::DashMap;
use std::sync::Arc;
use tokio::{task::JoinHandle, time::Duration};

use crate::context::{CursorId, CursorKey, CursorRef, CursorStoreEntry, TransactionNumber};
use crate::security::principal::Principal;
use crate::{configuration::DynamicConfiguration, context::SessionId};

// Maps CursorKey -> Connection, Cursor
#[derive(Debug)]
pub struct CursorStore {
    cursors: Arc<DashMap<CursorKey, CursorStoreEntry>>,
    _reaper: Option<JoinHandle<()>>,
}

impl Default for CursorStore {
    fn default() -> Self {
        Self::new()
    }
}

impl CursorStore {
    #[must_use]
    pub fn new() -> Self {
        Self {
            cursors: Arc::new(DashMap::new()),
            _reaper: None,
        }
    }

    pub fn with_reaper(config: Arc<dyn DynamicConfiguration>, use_reaper: bool) -> Self {
        let cursors: Arc<DashMap<CursorKey, CursorStoreEntry>> = Arc::new(DashMap::new());
        let cursors_clone = Arc::clone(&cursors);
        let reaper = use_reaper.then(|| {
            tokio::spawn(async move {
                let mut cursor_timeout_resolution =
                    Duration::from_secs(config.cursor_resolution_interval());
                let mut interval = tokio::time::interval(cursor_timeout_resolution);
                loop {
                    interval.tick().await;
                    cursors_clone.retain(|_, v| v.timestamp.elapsed() < v.cursor_timeout);

                    let new_timeout_interval =
                        Duration::from_secs(config.cursor_resolution_interval());
                    if new_timeout_interval != cursor_timeout_resolution {
                        cursor_timeout_resolution = new_timeout_interval;
                        interval = tokio::time::interval(cursor_timeout_resolution);
                    }
                }
            })
        });

        Self {
            cursors,
            _reaper: reaper,
        }
    }

    pub fn add_cursor(&self, k: CursorKey, v: CursorStoreEntry) {
        self.cursors.insert(k, v);
    }

    #[must_use]
    pub fn get_cursor(&self, k: &CursorKey) -> Option<CursorStoreEntry> {
        self.cursors.remove(k).map(|(_, v)| v)
    }

    #[must_use]
    pub fn get_cursor_ref(&self, k: &CursorKey) -> Option<CursorRef> {
        self.cursors.get(k).map(|v| {
            let entry = v.value();
            CursorRef::new(
                entry.cursor.cursor_id,
                entry.session_id.clone(),
                entry.transaction_number,
            )
        })
    }

    pub fn invalidate_cursors_by_collection(&self, db: &str, collection: &str) {
        self.cursors
            .retain(|_, v| !(v.collection == collection && v.db == db));
    }

    pub fn invalidate_cursors_by_database(&self, db: &str) {
        self.cursors.retain(|_, v| v.db != db);
    }

    #[must_use]
    pub fn invalidate_cursors_by_session(&self, session: &SessionId) -> Vec<i64> {
        let mut invalidated_cursor_ids = Vec::new();
        self.cursors.retain(|key, v| {
            let should_remove = v.session_id.as_ref() == Some(session);
            if should_remove {
                invalidated_cursor_ids.push(key.id().into());
            }
            !should_remove
        });
        invalidated_cursor_ids
    }

    #[must_use]
    pub fn invalidate_cursors_by_transaction(
        &self,
        transaction_number: TransactionNumber,
    ) -> Vec<i64> {
        let mut invalidated_cursor_ids = Vec::new();
        self.cursors.retain(|key, v| {
            let should_remove = v.transaction_number == Some(transaction_number);
            if should_remove {
                invalidated_cursor_ids.push(key.id().into());
            }
            !should_remove
        });
        invalidated_cursor_ids
    }

    #[must_use]
    pub fn kill_cursors(&self, cursors: &[i64], caller: &Principal) -> (Vec<i64>, Vec<i64>) {
        let mut removed_cursors = Vec::new();
        let mut missing_cursors = Vec::new();

        for cursor in cursors {
            let key = CursorKey::new(CursorId::from(*cursor), caller.clone());
            if self.cursors.remove(&key).is_some() {
                removed_cursors.push(*cursor);
            } else {
                missing_cursors.push(*cursor);
            }
        }
        (removed_cursors, missing_cursors)
    }
}

#[cfg(test)]
mod tests {
    use crate::principal;

    use super::*;
    use bson::RawDocumentBuf;
    use tokio::time::Instant;

    use super::super::Cursor;

    fn make_store() -> CursorStore {
        CursorStore {
            cursors: Arc::new(DashMap::new()),
            _reaper: None,
        }
    }

    fn make_entry(session_id: Option<SessionId>) -> CursorStoreEntry {
        CursorStoreEntry {
            conn: None,
            cursor: Cursor {
                continuation: RawDocumentBuf::new(),
                cursor_id: CursorId::new(0),
            },
            db: "testdb".to_owned(),
            collection: "testcol".to_owned(),
            timestamp: Instant::now(),
            cursor_timeout: Duration::from_secs(600),
            session_id,
            transaction_number: Some(TransactionNumber::new(1)),
        }
    }

    fn key(cursor_id: i64, caller: &Principal) -> CursorKey {
        CursorKey::new(cursor_id.into(), caller.clone())
    }

    #[test]
    fn store_add_and_get() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));
        let entry = store.get_cursor(&key(1, &principal!("alice", 1)));
        assert!(entry.is_some());
    }

    #[test]
    fn store_get_removes_entry() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));
        let _ = store.get_cursor(&key(1, &principal!("alice", 1)));
        // second get should return None
        assert!(store.get_cursor(&key(1, &principal!("alice", 1))).is_none());
    }

    #[test]
    fn store_different_user_cannot_get_cursor() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));
        assert!(
            store.get_cursor(&key(1, &principal!("bob", 2))).is_none(),
            "bob must not access alice's cursor"
        );
        // alice's cursor should still be there
        assert!(store.get_cursor(&key(1, &principal!("alice", 1))).is_some());
    }

    #[test]
    fn store_invalidate_by_collection() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));

        let mut other = make_entry(None);
        other.collection = "other".to_owned();
        store.add_cursor(key(2, &principal!("alice", 1)), other);

        store.invalidate_cursors_by_collection("testdb", "testcol");

        assert!(store.get_cursor(&key(1, &principal!("alice", 1))).is_none());
        assert!(store.get_cursor(&key(2, &principal!("alice", 1))).is_some());
    }

    #[test]
    fn store_invalidate_by_database() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));

        let mut other = make_entry(None);
        other.db = "otherdb".to_owned();
        store.add_cursor(key(2, &principal!("alice", 1)), other);

        store.invalidate_cursors_by_database("testdb");

        assert!(store.get_cursor(&key(1, &principal!("alice", 1))).is_none());
        assert!(store.get_cursor(&key(2, &principal!("alice", 1))).is_some());
    }

    #[test]
    fn store_invalidate_by_session() {
        let store = make_store();
        let sid = SessionId::new(vec![1, 2, 3]);
        store.add_cursor(
            key(1, &principal!("alice", 1)),
            make_entry(Some(sid.clone())),
        );
        store.add_cursor(key(2, &principal!("alice", 1)), make_entry(None));

        let invalidated = store.invalidate_cursors_by_session(&sid);
        assert_eq!(invalidated, vec![1_i64]);
        assert!(store.get_cursor(&key(1, &principal!("alice", 1))).is_none());
        assert!(store.get_cursor(&key(2, &principal!("alice", 1))).is_some());
    }

    #[test]
    fn store_kill_cursors_respects_user() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));
        store.add_cursor(key(2, &principal!("alice", 1)), make_entry(None));

        // bob tries to kill alice's cursors
        let (removed, missing) = store.kill_cursors(&[1_i64, 2], &principal!("bob", 2));
        assert!(removed.is_empty(), "bob must not kill alice's cursors");
        assert_eq!(missing, vec![1_i64, 2]);

        // alice kills her own
        let (removed, missing) = store.kill_cursors(&[1_i64, 2], &principal!("alice", 1));
        assert_eq!(removed, vec![1_i64, 2]);
        assert!(missing.is_empty());
    }

    #[test]
    fn store_kill_cursors_partial() {
        let store = make_store();
        store.add_cursor(key(1, &principal!("alice", 1)), make_entry(None));

        let (removed, missing) = store.kill_cursors(&[1_i64, 99], &principal!("alice", 1));
        assert_eq!(removed, vec![1_i64]);
        assert_eq!(missing, vec![99_i64]);
    }
}
