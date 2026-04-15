/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/cursor/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;
use std::sync::Arc;
use tokio::time::{Duration, Instant};

use crate::context::cursor::CursorId;
use crate::{context::SessionId, postgres::conn_mgmt::Connection};

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

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
}
