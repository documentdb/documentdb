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

use crate::context::cursor::{CursorId, CursorKey, CursorStoreEntry};
use crate::{configuration::DynamicConfiguration, context::SessionId};

// Maps CursorKey -> Connection, Cursor
#[derive(Debug)]
pub struct CursorStore {
    cursors: Arc<DashMap<CursorKey, CursorStoreEntry>>,
    _reaper: Option<JoinHandle<()>>,
}

impl CursorStore {
    pub fn new(config: Arc<dyn DynamicConfiguration>, use_reaper: bool) -> Self {
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
                invalidated_cursor_ids.push(i64::from(key.cursor_id));
            }
            !should_remove
        });
        invalidated_cursor_ids
    }

    #[must_use]
    pub fn kill_cursors(&self, user: &str, cursors: &[i64]) -> (Vec<i64>, Vec<i64>) {
        let mut removed_cursors = Vec::new();
        let mut missing_cursors = Vec::new();

        for cursor in cursors {
            let key = CursorKey {
                cursor_id: CursorId::from(*cursor),
                username: user.to_owned(),
            };
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
        }
    }

    fn key(cursor_id: i64, user: &str) -> CursorKey {
        CursorKey {
            cursor_id: CursorId::new(cursor_id),
            username: user.to_owned(),
        }
    }

    #[test]
    fn store_add_and_get() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));
        let entry = store.get_cursor(&key(1, "alice"));
        assert!(entry.is_some());
    }

    #[test]
    fn store_get_removes_entry() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));
        let _ = store.get_cursor(&key(1, "alice"));
        // second get should return None
        assert!(store.get_cursor(&key(1, "alice")).is_none());
    }

    #[test]
    fn store_different_user_cannot_get_cursor() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));
        assert!(
            store.get_cursor(&key(1, "bob")).is_none(),
            "bob must not access alice's cursor"
        );
        // alice's cursor should still be there
        assert!(store.get_cursor(&key(1, "alice")).is_some());
    }

    #[test]
    fn store_invalidate_by_collection() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));

        let mut other = make_entry(None);
        other.collection = "other".to_owned();
        store.add_cursor(key(2, "alice"), other);

        store.invalidate_cursors_by_collection("testdb", "testcol");

        assert!(store.get_cursor(&key(1, "alice")).is_none());
        assert!(store.get_cursor(&key(2, "alice")).is_some());
    }

    #[test]
    fn store_invalidate_by_database() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));

        let mut other = make_entry(None);
        other.db = "otherdb".to_owned();
        store.add_cursor(key(2, "alice"), other);

        store.invalidate_cursors_by_database("testdb");

        assert!(store.get_cursor(&key(1, "alice")).is_none());
        assert!(store.get_cursor(&key(2, "alice")).is_some());
    }

    #[test]
    fn store_invalidate_by_session() {
        let store = make_store();
        let sid = SessionId::new(vec![1, 2, 3]);
        store.add_cursor(key(1, "alice"), make_entry(Some(sid.clone())));
        store.add_cursor(key(2, "alice"), make_entry(None));

        let invalidated = store.invalidate_cursors_by_session(&sid);
        assert_eq!(invalidated, vec![1_i64]);
        assert!(store.get_cursor(&key(1, "alice")).is_none());
        assert!(store.get_cursor(&key(2, "alice")).is_some());
    }

    #[test]
    fn store_kill_cursors_respects_user() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));
        store.add_cursor(key(2, "alice"), make_entry(None));

        // bob tries to kill alice's cursors
        let (removed, missing) = store.kill_cursors("bob", &[1, 2]);
        assert!(removed.is_empty(), "bob must not kill alice's cursors");
        assert_eq!(missing, vec![1, 2]);

        // alice kills her own
        let (removed, missing) = store.kill_cursors("alice", &[1, 2]);
        assert_eq!(removed, vec![1, 2]);
        assert!(missing.is_empty());
    }

    #[test]
    fn store_kill_cursors_partial() {
        let store = make_store();
        store.add_cursor(key(1, "alice"), make_entry(None));

        let (removed, missing) = store.kill_cursors("alice", &[1, 99]);
        assert_eq!(removed, vec![1]);
        assert_eq!(missing, vec![99]);
    }
}
