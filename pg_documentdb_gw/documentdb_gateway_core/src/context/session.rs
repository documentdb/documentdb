/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/session.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt;

#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(Vec<u8>);

impl SessionId {
    #[must_use]
    pub const fn new(id: Vec<u8>) -> Self {
        Self(id)
    }

    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl From<Vec<u8>> for SessionId {
    fn from(value: Vec<u8>) -> Self {
        Self(value)
    }
}

impl From<&[u8]> for SessionId {
    fn from(value: &[u8]) -> Self {
        Self(value.to_vec())
    }
}

impl From<SessionId> for Vec<u8> {
    fn from(session_id: SessionId) -> Self {
        session_id.0
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", hex::encode(&self.0))
    }
}

impl fmt::Debug for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SessionId({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_stores_bytes() {
        let bytes = vec![1, 2, 3, 4];
        let id = SessionId::new(bytes.clone());
        assert_eq!(id.as_bytes(), &bytes);
    }

    #[test]
    fn from_vec_u8() {
        let bytes = vec![10, 20, 30];
        let id: SessionId = bytes.clone().into();
        assert_eq!(id.as_bytes(), &bytes);
    }

    #[test]
    fn from_slice() {
        let bytes: &[u8] = &[5, 6, 7, 8];
        let id: SessionId = bytes.into();
        assert_eq!(id.as_bytes(), bytes);
    }

    #[test]
    fn into_vec_u8() {
        let bytes = vec![99, 100];
        let id = SessionId::new(bytes.clone());
        let recovered: Vec<u8> = id.into();
        assert_eq!(recovered, bytes);
    }

    #[test]
    fn clone_produces_equal_instance() {
        let id = SessionId::new(vec![1, 2, 3]);
        let cloned = id.clone();
        assert_eq!(id, cloned);
    }

    #[test]
    fn equality() {
        let a = SessionId::new(vec![1, 2, 3]);
        let b = SessionId::new(vec![1, 2, 3]);
        let c = SessionId::new(vec![4, 5, 6]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn hash_consistent_with_equality() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let a = SessionId::new(vec![1, 2, 3]);
        let b = SessionId::new(vec![1, 2, 3]);

        let hash = |val: &SessionId| {
            let mut h = DefaultHasher::new();
            val.hash(&mut h);
            h.finish()
        };

        assert_eq!(hash(&a), hash(&b));
    }

    #[test]
    fn debug_format_shows_hex() {
        let id = SessionId::new(vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let debug = format!("{id:?}");
        assert_eq!(debug, "SessionId(deadbeef)");
    }

    #[test]
    fn empty_session_id() {
        let id = SessionId::new(vec![]);
        assert!(id.as_bytes().is_empty());
        assert_eq!(format!("{id:?}"), "SessionId()");
    }

    #[test]
    fn can_be_used_as_hash_map_key() {
        use std::collections::HashMap;

        let id1 = SessionId::new(vec![1, 2, 3]);
        let id2 = SessionId::new(vec![4, 5, 6]);
        let mut map = HashMap::new();
        map.insert(id1.clone(), "first");
        map.insert(id2.clone(), "second");

        assert_eq!(map.get(&id1), Some(&"first"));
        assert_eq!(map.get(&id2), Some(&"second"));
    }
}
