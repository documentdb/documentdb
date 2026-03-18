/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/mod.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod read_concern;
pub mod read_preference;
pub mod request_tracker;
pub mod request_type;
pub mod validation;

use std::{fmt::Debug, str::FromStr};

use bson::{spec::ElementType, Document, RawBsonRef, RawDocument, RawDocumentBuf};
use read_concern::ReadConcern;
use read_preference::ReadPreference;
use tokio_postgres::IsolationLevel;

use crate::{
    bson::convert_to_f64,
    context::RequestTransactionInfo,
    error::{DocumentDBError, ErrorCode, Result},
    protocol::opcode::OpCode,
};

pub use request_tracker::RequestIntervalKind;
pub use request_type::RequestType;

/// The `RequestMessage` holds ownership to the whole client message.
///
/// Other objects, like the `Request` will only hold references to it.
#[derive(Debug)]
pub struct RequestMessage {
    pub request: Vec<u8>,
    pub op_code: OpCode,
    pub request_id: i32,
    pub response_to: i32,
}

#[derive(Debug)]
pub enum Request<'a> {
    Raw(RequestType, &'a RawDocument, Option<&'a [u8]>),
    RawBuf(RequestType, RawDocumentBuf),
}

#[derive(Debug, Default)]
pub struct RequestInfo<'a> {
    pub max_time_ms: Option<i64>,
    pub transaction_info: Option<RequestTransactionInfo>,
    db: Option<&'a str>,
    collection: Option<&'a str>,
    pub session_id: Option<&'a [u8]>,
    read_concern: ReadConcern,
}

impl RequestInfo<'_> {
    #[must_use]
    pub fn new() -> Self {
        Self {
            max_time_ms: None,
            transaction_info: None,
            db: None,
            collection: None,
            session_id: None,
            read_concern: ReadConcern::default(),
        }
    }

    /// # Errors
    /// Returns error if the collection is not set.
    pub fn collection(&self) -> Result<&str> {
        self.collection.ok_or(DocumentDBError::documentdb_error(
            ErrorCode::InvalidNamespace,
            "Invalid namespace".to_owned(),
        ))
    }

    /// # Errors
    /// Returns error if `$db` is not set.
    pub fn db(&self) -> Result<&str> {
        self.db.ok_or(DocumentDBError::bad_value(
            "Expected $db to be present".to_owned(),
        ))
    }

    #[must_use]
    pub const fn read_concern(&self) -> &ReadConcern {
        &self.read_concern
    }
}

impl<'a> Request<'a> {
    /// # Errors
    /// Returns error if BSON to document conversion fails.
    pub fn to_json(&self) -> Result<Document> {
        Ok(match self {
            Self::Raw(_, body, _) => Document::try_from(*body)?,
            Self::RawBuf(_, body) => body.to_document()?,
        })
    }

    #[must_use]
    pub const fn request_type(&self) -> RequestType {
        match self {
            Self::Raw(t, _, _) | Self::RawBuf(t, _) => *t,
        }
    }

    #[must_use]
    pub fn document(&'a self) -> &'a RawDocument {
        match self {
            Self::Raw(_, d, _) => d,
            Self::RawBuf(_, d) => d,
        }
    }

    #[must_use]
    pub const fn extra(&'a self) -> Option<&'a [u8]> {
        match self {
            Self::Raw(_, _, extra) => *extra,
            Self::RawBuf(_, _) => None,
        }
    }

    /// # Errors
    /// Returns error if `$db` field is missing or not a string.
    pub fn db(&self) -> Result<&str> {
        self.document()
            .get_str("$db")
            .map_err(DocumentDBError::parse_failure())
    }

    /// # Errors
    /// Returns error if field extraction fails.
    pub fn extract_fields<F>(&self, mut f: F) -> Result<()>
    where
        F: FnMut(&str, RawBsonRef) -> Result<()>,
    {
        for entry in self.document() {
            let (k, v) = entry?;
            f(k, v)?;
        }
        Ok(())
    }

    #[expect(clippy::expect_used, reason = "element type checked before access")]
    #[expect(
        clippy::cast_possible_truncation,
        reason = "truncation acceptable for f64 to i64 conversion"
    )]
    fn to_i64(bson: RawBsonRef) -> Result<i64> {
        match bson.element_type() {
            ElementType::Int32 => Ok(i64::from(bson.as_i32().expect("Checked"))),
            ElementType::Int64 => Ok(bson.as_i64().expect("Checked")),
            ElementType::Double => Ok(bson.as_f64().expect("Checked") as i64),
            _ => Err(DocumentDBError::documentdb_error(
                ErrorCode::TypeMismatch,
                "Unexpected type".to_owned(),
            )),
        }
    }

    /// # Errors
    /// Returns error if common field extraction fails.
    pub fn extract_common(&'a self) -> Result<RequestInfo<'a>> {
        self.extract_fields_and_common(|_, _| Ok(()))
    }

    /// # Errors
    /// Returns error if collection or common field extraction fails.
    pub fn extract_coll_and_common(
        &'a self,
        collection_key: &str,
    ) -> Result<(String, RequestInfo<'a>)> {
        let mut collection = None;
        let request_info = self.extract_fields_and_common(|k, v| {
            if k == collection_key {
                collection = Some(
                    v.as_str()
                        .ok_or(DocumentDBError::documentdb_error(
                            ErrorCode::InvalidNamespace,
                            "Invalid namespace".to_owned(),
                        ))?
                        .to_owned(),
                );
            }
            Ok(())
        })?;
        Ok((
            collection.ok_or(DocumentDBError::bad_value(format!(
                "{collection_key} should be present"
            )))?,
            request_info,
        ))
    }

    /// # Errors
    /// Returns error if field extraction or parsing fails.
    #[expect(clippy::too_many_lines, reason = "complex field extraction logic")]
    pub fn extract_fields_and_common<F>(&'a self, mut coll_extractor: F) -> Result<RequestInfo<'a>>
    where
        F: FnMut(&str, RawBsonRef) -> Result<()>,
    {
        let mut max_time_ms = None;
        let mut db = None;
        let mut session_id: Option<&[u8]> = None;
        let mut transaction_number: Option<i64> = None;
        let mut auto_commit = true;
        let mut start_transaction = false;
        let mut isolation_level = None;
        let mut collection = None;
        let mut read_concern = ReadConcern::default();

        let collection_field = self.collection_field();
        for entry in self.document() {
            let (k, v) = entry?;
            match k {
                "$db" => {
                    db = Some(v.as_str().ok_or(DocumentDBError::bad_value(format!(
                        "Expected $db to be a string but got {:?}",
                        v.element_type()
                    )))?);
                }
                "maxTimeMS" => max_time_ms = Some(Self::to_i64(v)?),
                "lsid" => {
                    session_id = Some(
                        v.as_document()
                            .ok_or(DocumentDBError::bad_value(format!(
                                "Expected lsid to be a document but got {:?}",
                                v.element_type()
                            )))?
                            .get_binary("id")
                            .map_err(DocumentDBError::parse_failure())?
                            .bytes,
                    );
                }
                "txnNumber" => {
                    transaction_number =
                        Some(v.as_i64().ok_or(DocumentDBError::bad_value(format!(
                            "Expected txnNumber to be an i64 but got {:?}",
                            v.element_type()
                        )))?);
                }
                "autocommit" => {
                    auto_commit = v.as_bool().ok_or(DocumentDBError::bad_value(format!(
                        "Expected autocommit to be a bool but got {:?}",
                        v.element_type()
                    )))?;
                }
                "startTransaction" => {
                    start_transaction = v.as_bool().ok_or(DocumentDBError::bad_value(format!(
                        "Expected startTransaction to be a bool but got {:?}",
                        v.element_type()
                    )))?;
                }
                "readConcern" => {
                    let level = v
                        .as_document()
                        .ok_or(DocumentDBError::bad_value(format!(
                            "Expected readConcern to be a document but got {:?}",
                            v.element_type()
                        )))?
                        .get_str("level")
                        .unwrap_or("");
                    read_concern = ReadConcern::from_str(level).unwrap_or(ReadConcern::default());
                    if read_concern == ReadConcern::Snapshot {
                        isolation_level = Some(IsolationLevel::RepeatableRead);
                    }
                }
                "$readPreference" => ReadPreference::parse(v.as_document())?,
                key if collection_field.contains(&key) => {
                    // Aggregate needs special handling because having '1' as a collection is valid
                    collection = if collection_field[0] == "aggregate" {
                        Some(
                            convert_to_f64(v)
                                .map_or_else(|| v.as_str(), |_| Some(""))
                                .ok_or(DocumentDBError::bad_value(format!(
                                    "Failed to parse aggregate key; expected string or numeric but got {:?}",
                                    v.element_type()
                                )))?,
                        )
                    } else {
                        v.as_str()
                    }
                }
                _ => coll_extractor(k, v)?,
            }
        }
        let transaction_info = match (&session_id, transaction_number) {
            (Some(_), Some(transaction_number)) => Some(RequestTransactionInfo {
                transaction_number,
                auto_commit,
                start_transaction,
                is_request_within_transaction: !auto_commit,
                isolation_level,
            }),
            _ => None,
        };

        Ok(RequestInfo {
            max_time_ms,
            transaction_info,
            db,
            collection,
            session_id,
            read_concern,
        })
    }

    const fn collection_field(&self) -> &[&'static str] {
        match self.request_type() {
            RequestType::Aggregate => &["aggregate"],
            RequestType::CollMod => &["collMod"],
            RequestType::CollStats => &["collStats"],
            RequestType::Compact => &["compact"],
            RequestType::Count => &["count"],
            RequestType::Create => &["create"],
            RequestType::CreateIndex => &["createIndex"],
            RequestType::CreateIndexes => &["createIndexes"],
            RequestType::Delete => &["delete"],
            RequestType::Distinct => &["distinct"],
            RequestType::Drop => &["drop"],
            RequestType::DropIndexes => &["dropIndexes"],
            RequestType::Find => &["find"],
            RequestType::FindAndModify => &["findAndModify"],
            RequestType::Insert => &["insert"],
            RequestType::ListIndexes => &["listIndexes"],
            RequestType::ReIndex => &["reIndex", "reindex"],
            RequestType::RenameCollection => &["renameCollection"],
            RequestType::ReshardCollection => &["reshardCollection"],
            RequestType::ShardCollection => &["shardCollection"],
            RequestType::UnshardCollection => &["unshardCollection"],
            RequestType::Update => &["update"],
            _ => &[],
        }
    }
}
