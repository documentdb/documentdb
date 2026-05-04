/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/store_key.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::security::principal::Principal;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StoreKey<K> {
    id: K,
    owner: Principal,
}

impl<K> StoreKey<K> {
    pub const fn new(id: K, owner: Principal) -> Self {
        Self { id, owner }
    }

    pub const fn id(&self) -> &K {
        &self.id
    }

    pub const fn owner(&self) -> &Principal {
        &self.owner
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use crate::context::CursorId;

    use super::*;

    type ExampleCursorKey = StoreKey<CursorId>;

    #[test]
    fn cursor_key_equal_when_both_fields_match() {
        let k1 = ExampleCursorKey {
            id: CursorId::new(1),
            owner: Principal::new("alice".to_owned(), 3),
        };

        let k2 = ExampleCursorKey {
            id: CursorId::new(1),
            owner: Principal::new("alice".to_owned(), 3),
        };

        assert_eq!(k1, k2);
    }

    #[test]
    fn cursor_key_different_user_same_cursor_id() {
        let k1 = ExampleCursorKey {
            id: CursorId::new(1),
            owner: Principal::new("alice".to_owned(), 3),
        };
        let k2 = ExampleCursorKey {
            id: CursorId::new(1),
            owner: Principal::new("bob".to_owned(), 3),
        };
        assert_ne!(k1, k2, "different users must not share cursor keys");
    }

    #[test]
    fn cursor_key_same_user_different_cursor_id() {
        let k1 = ExampleCursorKey {
            id: CursorId::new(1),
            owner: Principal::new("alice".to_owned(), 3),
        };
        let k2 = ExampleCursorKey {
            id: CursorId::new(2),
            owner: Principal::new("alice".to_owned(), 3),
        };
        assert_ne!(k1, k2);
    }

    #[test]
    fn cursor_key_hash_consistent_with_equality() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let k1 = ExampleCursorKey {
            id: CursorId::new(5),
            owner: Principal::new("charlie".to_owned(), 3),
        };
        let k2 = ExampleCursorKey {
            id: CursorId::new(5),
            owner: Principal::new("charlie".to_owned(), 3),
        };
        let hash = |k: &ExampleCursorKey| {
            let mut h = DefaultHasher::new();
            k.hash(&mut h);
            h.finish()
        };
        assert_eq!(hash(&k1), hash(&k2));
    }

    #[test]
    fn cursor_key_works_as_hash_map_key() {
        let mut map = HashMap::new();
        let k = ExampleCursorKey {
            id: CursorId::new(10),
            owner: Principal::new("alice".to_owned(), 3),
        };
        map.insert(k.clone(), "value");
        assert_eq!(map.get(&k), Some(&"value"));

        // Same cursor_id, different user → miss
        let k2 = ExampleCursorKey {
            id: CursorId::new(10),
            owner: Principal::new("bob".to_owned(), 3),
        };
        assert_eq!(map.get(&k2), None);
    }
}
