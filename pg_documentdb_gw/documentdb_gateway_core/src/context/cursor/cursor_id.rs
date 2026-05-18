/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/cursor/cursor_id.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt;

use crate::context::{LogicalSessionId, StoreKey, TransactionNumber};

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CursorId(i64);

pub type CursorKey = StoreKey<CursorId>;

#[derive(Debug)]
pub struct CursorRef {
    cursor_id: CursorId,
    lsid: Option<LogicalSessionId>,
    transaction_number: Option<TransactionNumber>,
}

impl CursorRef {
    #[must_use]
    pub const fn new(
        cursor_id: CursorId,
        lsid: Option<LogicalSessionId>,
        transaction_number: Option<TransactionNumber>,
    ) -> Self {
        Self {
            cursor_id,
            lsid,
            transaction_number,
        }
    }

    #[must_use]
    pub const fn cursor_id(&self) -> &CursorId {
        &self.cursor_id
    }

    #[must_use]
    pub const fn lsid(&self) -> Option<&LogicalSessionId> {
        self.lsid.as_ref()
    }

    #[must_use]
    pub const fn transaction_number(&self) -> Option<&TransactionNumber> {
        self.transaction_number.as_ref()
    }
}

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

impl From<&CursorId> for i64 {
    fn from(cursor_id: &CursorId) -> Self {
        cursor_id.0
    }
}

impl fmt::Display for CursorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for CursorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "CursorId({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
