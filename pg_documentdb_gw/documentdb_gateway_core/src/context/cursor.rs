/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::RawDocumentBuf;
use dashmap::DashMap;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};

use crate::{
    configuration::DynamicConfiguration, context::SessionId, postgres::conn_mgmt::Connection,
};

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CursorId(i64);

impl CursorId {
    #[must_use]
    pub const fn new(cursor_id: i64) -> Self {
        Self(cursor_id)
    }
}

impl From<i64> for CursorId {
    fn from(value: i64) -> Self {
        Self(value)
    }
}

impl From<&i64> for CursorId {
    fn from(value: &i64) -> Self {
        Self(*value)
    }
}

impl From<CursorId> for i64 {
    fn from(cursor_id: CursorId) -> Self {
        cursor_id.0
    }
}

impl std::fmt::Display for CursorId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::fmt::Debug for CursorId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CursorId({self})")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CursorKey {
    pub cursor_id: CursorId,
    pub username: String,
}

#[derive(Debug)]
pub struct Cursor {
    pub continuation: RawDocumentBuf,
    pub cursor_id: CursorId,
}

#[derive(Debug)]
pub struct CursorStoreEntry {
    pub conn: Option<Arc<Connection>>,
    pub cursor: Cursor,
    pub db: String,
    pub collection: String,
    pub timestamp: Instant,
    pub cursor_timeout: Duration,
    pub session_id: Option<SessionId>,
}

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
    use std::collections::HashMap;

    // ── CursorId tests ──

    #[test]
    fn cursor_id_new_and_from() {
        let id = CursorId::new(42);
        assert_eq!(i64::from(id), 42);

        let id2 = CursorId::from(42_i64);
        assert_eq!(id, id2);

        let id3 = CursorId::from(&42_i64);
        assert_eq!(id, id3);
    }

    #[test]
    fn cursor_id_display_and_debug() {
        let id = CursorId::new(99);
        assert_eq!(format!("{id}"), "99");
        assert_eq!(format!("{id:?}"), "CursorId(99)");
    }

    #[test]
    fn cursor_id_equality() {
        assert_eq!(CursorId::new(1), CursorId::new(1));
        assert_ne!(CursorId::new(1), CursorId::new(2));
    }

    #[test]
    fn cursor_id_copy_semantics() {
        let id = CursorId::new(7);
        let id2 = id; // Copy, not move
        assert_eq!(id, id2);
    }

    // ── CursorKey tests ──

    #[test]
    fn cursor_key_equal_when_both_fields_match() {
        let k1 = CursorKey {
            cursor_id: CursorId::new(1),
            username: "alice".to_owned(),
        };
        let k2 = CursorKey {
            cursor_id: CursorId::new(1),
            username: "alice".to_owned(),
        };
        assert_eq!(k1, k2);
    }

    #[test]
    fn cursor_key_different_user_same_cursor_id() {
        let k1 = CursorKey {
            cursor_id: CursorId::new(1),
            username: "alice".to_owned(),
        };
        let k2 = CursorKey {
            cursor_id: CursorId::new(1),
            username: "bob".to_owned(),
        };
        assert_ne!(k1, k2, "different users must not share cursor keys");
    }

    #[test]
    fn cursor_key_same_user_different_cursor_id() {
        let k1 = CursorKey {
            cursor_id: CursorId::new(1),
            username: "alice".to_owned(),
        };
        let k2 = CursorKey {
            cursor_id: CursorId::new(2),
            username: "alice".to_owned(),
        };
        assert_ne!(k1, k2);
    }

    #[test]
    fn cursor_key_hash_consistent_with_equality() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let k1 = CursorKey {
            cursor_id: CursorId::new(5),
            username: "charlie".to_owned(),
        };
        let k2 = CursorKey {
            cursor_id: CursorId::new(5),
            username: "charlie".to_owned(),
        };
        let hash = |k: &CursorKey| {
            let mut h = DefaultHasher::new();
            k.hash(&mut h);
            h.finish()
        };
        assert_eq!(hash(&k1), hash(&k2));
    }

    #[test]
    fn cursor_key_works_as_hash_map_key() {
        let mut map = HashMap::new();
        let k = CursorKey {
            cursor_id: CursorId::new(10),
            username: "alice".to_owned(),
        };
        map.insert(k.clone(), "value");
        assert_eq!(map.get(&k), Some(&"value"));

        // Same cursor_id, different user → miss
        let k2 = CursorKey {
            cursor_id: CursorId::new(10),
            username: "bob".to_owned(),
        };
        assert_eq!(map.get(&k2), None);
    }

    // ── CursorStore tests (no reaper, no tokio runtime needed for basic ops) ──

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
