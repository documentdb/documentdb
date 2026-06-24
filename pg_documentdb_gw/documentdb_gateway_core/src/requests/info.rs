/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/info.rs
 *
 *-------------------------------------------------------------------------
 */

use std::borrow::Cow;

use tokio_postgres::IsolationLevel;

use crate::{
    context::{LogicalSessionId, RequestTransactionInfo, TransactionNumber},
    error::{DocumentDBError, ErrorCode, Result},
    requests::read_concern::ReadConcern,
};

#[derive(Clone, Debug, Default)]
pub struct RequestInfo<'a> {
    pub max_time_ms: Option<i64>,
    pub transaction_info: Option<RequestTransactionInfo>,
    db: Option<Cow<'a, str>>,
    collection: Option<Cow<'a, str>>,
    pub lsid: Option<LogicalSessionId>,
    read_concern: ReadConcern,
    explain: bool,
}

impl<'a> RequestInfo<'a> {
    #[must_use]
    pub(super) fn builder() -> RequestInfoBuilder<'a> {
        RequestInfoBuilder::new()
    }

    #[cfg(test)]
    /// # Errors
    /// Returns error if the collection is not set.
    pub(crate) fn collection(&self) -> Result<&str> {
        self.collection
            .as_deref()
            .ok_or(DocumentDBError::documentdb_error(
                ErrorCode::InvalidNamespace,
                "Invalid namespace".to_owned(),
            ))
    }

    #[cfg(test)]
    /// # Errors
    /// Returns error if `$db` is not set.
    pub(crate) fn db(&self) -> Result<&str> {
        self.db.as_deref().ok_or(DocumentDBError::bad_value(
            "Expected $db to be present".to_owned(),
        ))
    }
}

#[derive(Clone, Debug)]
pub struct StrictRequestInfo<'a> {
    max_time_ms: Option<i64>,
    transaction_info: Option<RequestTransactionInfo>,
    db: Cow<'a, str>,
    collection: Option<Cow<'a, str>>,
    lsid: Option<LogicalSessionId>,
    read_concern: ReadConcern,
    explain: bool,
}

impl<'a> StrictRequestInfo<'a> {
    /// Converts lenient request metadata into strict executable metadata.
    ///
    /// # Errors
    /// Returns an error if `$db` is not set.
    pub(crate) fn try_from_info(info: RequestInfo<'a>) -> Result<Self> {
        let db = info.db.ok_or(DocumentDBError::bad_value(
            "Expected $db to be present".to_owned(),
        ))?;

        Ok(Self {
            max_time_ms: info.max_time_ms,
            transaction_info: info.transaction_info,
            db,
            collection: info.collection,
            lsid: info.lsid,
            read_concern: info.read_concern,
            explain: info.explain,
        })
    }

    #[must_use]
    pub(crate) fn into_owned_metadata(self) -> StrictRequestInfo<'static> {
        StrictRequestInfo {
            max_time_ms: self.max_time_ms,
            transaction_info: self.transaction_info,
            db: Cow::Owned(self.db.into_owned()),
            collection: self
                .collection
                .map(|collection| Cow::Owned(collection.into_owned())),
            lsid: self.lsid,
            read_concern: self.read_concern,
            explain: self.explain,
        }
    }

    #[must_use]
    pub(crate) fn db(&self) -> &str {
        &self.db
    }

    /// # Errors
    /// Returns error if the collection is not set.
    pub(crate) fn collection(&self) -> Result<&str> {
        self.collection
            .as_deref()
            .ok_or(DocumentDBError::documentdb_error(
                ErrorCode::InvalidNamespace,
                "Invalid namespace".to_owned(),
            ))
    }

    #[must_use]
    pub(crate) const fn max_time_ms(&self) -> Option<i64> {
        self.max_time_ms
    }

    #[must_use]
    pub(crate) const fn transaction_info(&self) -> Option<&RequestTransactionInfo> {
        self.transaction_info.as_ref()
    }

    #[must_use]
    pub(crate) const fn lsid(&self) -> Option<&LogicalSessionId> {
        self.lsid.as_ref()
    }

    #[must_use]
    pub(crate) const fn read_concern(&self) -> &ReadConcern {
        &self.read_concern
    }

    #[must_use]
    pub(crate) const fn is_explain(&self) -> bool {
        self.explain
    }
}

#[derive(Debug)]
pub(super) struct RequestInfoBuilder<'a> {
    max_time_ms: Option<i64>,
    transaction: RequestTransactionInfoBuilder,
    db: Option<Cow<'a, str>>,
    collection: Option<Cow<'a, str>>,
    lsid: Option<LogicalSessionId>,
    read_concern: ReadConcern,
    explain: bool,
}

impl<'a> RequestInfoBuilder<'a> {
    #[must_use]
    fn new() -> Self {
        Self {
            max_time_ms: None,
            transaction: RequestTransactionInfoBuilder::new(),
            db: None,
            collection: None,
            lsid: None,
            read_concern: ReadConcern::default(),
            explain: false,
        }
    }

    pub(super) const fn max_time_ms(&mut self, max_time_ms: i64) -> &mut Self {
        self.max_time_ms = Some(max_time_ms);
        self
    }

    pub(super) fn db(&mut self, db: &'a str) -> &mut Self {
        self.db = Some(Cow::Borrowed(db));
        self
    }

    pub(super) fn collection(&mut self, collection: Option<&'a str>) -> &mut Self {
        self.collection = match collection {
            Some(collection) => Some(Cow::Borrowed(collection)),
            None => None,
        };
        self
    }

    pub(super) fn lsid(&mut self, lsid: LogicalSessionId) -> &mut Self {
        self.lsid = Some(lsid);
        self
    }

    pub(super) const fn transaction_number(&mut self, transaction_number: i64) -> &mut Self {
        self.transaction
            .transaction_number(TransactionNumber::new(transaction_number));
        self
    }

    pub(super) const fn auto_commit(&mut self, auto_commit: bool) -> &mut Self {
        self.transaction.auto_commit(auto_commit);
        self
    }

    pub(super) const fn start_transaction(&mut self, start_transaction: bool) -> &mut Self {
        self.transaction.start_transaction(start_transaction);
        self
    }

    pub(super) const fn read_concern(&mut self, read_concern: ReadConcern) -> &mut Self {
        self.read_concern = read_concern;
        self
    }

    pub(super) const fn isolation_level(&mut self, isolation_level: IsolationLevel) -> &mut Self {
        self.transaction.isolation_level(isolation_level);
        self
    }

    pub(super) const fn explain(&mut self, explain: bool) -> &mut Self {
        self.explain = explain;
        self
    }

    #[must_use]
    pub(super) fn build(self) -> RequestInfo<'a> {
        let transaction_info = self.transaction.build(self.lsid.is_some());

        RequestInfo {
            max_time_ms: self.max_time_ms,
            transaction_info,
            db: self.db,
            collection: self.collection,
            lsid: self.lsid,
            read_concern: self.read_concern,
            explain: self.explain,
        }
    }
}

#[derive(Debug)]
struct RequestTransactionInfoBuilder {
    transaction_number: Option<TransactionNumber>,
    auto_commit: bool,
    start_transaction: bool,
    isolation_level: Option<IsolationLevel>,
}

impl RequestTransactionInfoBuilder {
    #[must_use]
    const fn new() -> Self {
        Self {
            transaction_number: None,
            auto_commit: true,
            start_transaction: false,
            isolation_level: None,
        }
    }

    const fn transaction_number(&mut self, transaction_number: TransactionNumber) -> &mut Self {
        self.transaction_number = Some(transaction_number);
        self
    }

    const fn auto_commit(&mut self, auto_commit: bool) -> &mut Self {
        self.auto_commit = auto_commit;
        self
    }

    const fn start_transaction(&mut self, start_transaction: bool) -> &mut Self {
        self.start_transaction = start_transaction;
        self
    }

    const fn isolation_level(&mut self, isolation_level: IsolationLevel) -> &mut Self {
        self.isolation_level = Some(isolation_level);
        self
    }

    #[must_use]
    fn build(self, has_session_id: bool) -> Option<RequestTransactionInfo> {
        has_session_id
            .then_some(self.transaction_number)
            .flatten()
            .map(|transaction_number| RequestTransactionInfo {
                transaction_number,
                auto_commit: self.auto_commit,
                start_transaction: self.start_transaction,
                is_request_within_transaction: !self.auto_commit,
                isolation_level: self.isolation_level,
            })
    }
}
