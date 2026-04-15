/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/transaction_number.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt;

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TransactionNumber(i64);

impl TransactionNumber {
    #[must_use]
    pub const fn new(transaction_number: i64) -> Self {
        Self(transaction_number)
    }
}

impl From<i64> for TransactionNumber {
    fn from(value: i64) -> Self {
        Self(value)
    }
}

impl From<&i64> for TransactionNumber {
    fn from(value: &i64) -> Self {
        Self(*value)
    }
}

impl From<TransactionNumber> for i64 {
    fn from(transaction_number: TransactionNumber) -> Self {
        transaction_number.0
    }
}

impl fmt::Display for TransactionNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for TransactionNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "TransactionNumber({self})")
    }
}
