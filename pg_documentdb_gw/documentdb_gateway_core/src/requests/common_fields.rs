/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/common_fields.rs
 *
 *-------------------------------------------------------------------------
 */

use std::str::FromStr;

use bson::RawDocument;
use tokio_postgres::IsolationLevel;

use crate::{
    error::{DocumentDBError, ErrorCode, Result},
    protocol::bson_scanner::{self, RawField},
    requests::{
        info::{RequestInfo, RequestInfoBuilder},
        read_concern::ReadConcern,
        read_preference::ReadPreference,
        request_type::RequestType,
    },
};

/// Returns the BSON field names that hold the collection name for a given request type.
const fn collection_fields_for(request_type: RequestType) -> &'static [&'static str] {
    match request_type {
        RequestType::Aggregate => &["aggregate"],
        RequestType::CollMod => &["collMod"],
        RequestType::CollStats => &["collStats"],
        RequestType::Compact => &["compact"],
        RequestType::Count => &["count"],
        RequestType::Create => &["create"],
        RequestType::CreateIndex => &["createIndex"],
        RequestType::CreateIndexes => &["createIndexes"],
        RequestType::CreateSearchIndexes => &["createSearchIndexes"],
        RequestType::Delete => &["delete"],
        RequestType::Distinct => &["distinct"],
        RequestType::Drop => &["drop"],
        RequestType::DropIndexes => &["dropIndexes"],
        RequestType::Find => &["find"],
        RequestType::FindAndModify => &["findAndModify"],
        RequestType::GetMore => &["collection"],
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

/// Extracts common metadata from a command document.
///
/// # Errors
///
/// Returns an error if a recognized common field has an invalid BSON type.
pub fn extract_info_from_document(
    document: &RawDocument,
    request_type: RequestType,
) -> Result<RequestInfo<'_>> {
    let mut request_info = RequestInfo::builder();
    let collection_field = collection_fields_for(request_type);

    bson_scanner::scan_document(document.as_bytes(), |field| {
        let key = field.name_str().ok_or_else(|| {
            DocumentDBError::bad_value("BSON field name is not valid UTF-8".to_owned())
        })?;
        extract_common_field(&mut request_info, key, &field, collection_field)
    })?;

    Ok(request_info.build())
}

/// Extracts the command type and common metadata from a command document in one scan.
///
/// # Errors
///
/// Returns an error if the document is empty, has an unrecognized command, or recognized common
/// metadata has an invalid BSON type.
pub fn extract_request_type_and_info_from_document(
    document: &RawDocument,
) -> Result<(RequestType, RequestInfo<'_>)> {
    let mut request_info = RequestInfo::builder();
    let mut request_type = None;

    bson_scanner::scan_document(document.as_bytes(), |field| {
        let key = field.name_str().ok_or_else(|| {
            DocumentDBError::bad_value("BSON field name is not valid UTF-8".to_owned())
        })?;

        let current_request_type = if let Some(request_type) = request_type {
            request_type
        } else {
            let parsed_type = RequestType::from_str(key)?;
            request_type = Some(parsed_type);
            parsed_type
        };

        extract_common_field(
            &mut request_info,
            key,
            &field,
            collection_fields_for(current_request_type),
        )
    })?;

    let request_type =
        request_type.ok_or_else(|| DocumentDBError::bad_value("Empty BSON document".to_owned()))?;

    Ok((request_type, request_info.build()))
}

#[expect(clippy::too_many_lines, reason = "complex field extraction logic")]
fn extract_common_field<'a>(
    request_info: &mut RequestInfoBuilder<'a>,
    key: &'a str,
    field: &RawField<'a>,
    collection_field: &[&str],
) -> Result<()> {
    match key {
        "$db" => {
            let db = field.as_str().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected $db to be a string but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            request_info.db(db);
        }
        "maxTimeMS" => {
            let max_time_ms = field.to_i64().ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::TypeMismatch,
                    "maxTimeMS must be a numeric type".to_owned(),
                )
            })?;

            request_info.max_time_ms(max_time_ms);
        }
        "lsid" => {
            // Nested document — use scanner recursively for binary extraction
            let doc_bytes = field.as_embedded_document_bytes().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected lsid to be a document but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            let mut seen_id = false;
            bson_scanner::scan_document(doc_bytes, |inner_field| {
                if inner_field.name() == b"id" {
                    if seen_id {
                        return Ok(());
                    }
                    seen_id = true;

                    let Some((_subtype, data)) = inner_field.as_binary_data() else {
                        return Err(DocumentDBError::bad_value(format!(
                            "Expected lsid.id to be binary but got element type 0x{:02X}",
                            inner_field.element_type()
                        )));
                    };

                    request_info.lsid(data.into());
                }
                Ok(())
            })?;

            if !seen_id {
                return Err(DocumentDBError::bad_value(
                    "lsid document missing 'id' binary field".to_owned(),
                ));
            }
        }
        "txnNumber" => {
            let txn_number = field.as_i64().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected txnNumber to be an i64 but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            request_info.transaction_number(txn_number);
        }
        "autocommit" => {
            let auto_commit = field.as_bool().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected autocommit to be a bool but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            request_info.auto_commit(auto_commit);
        }
        "startTransaction" => {
            let start_transaction = field.as_bool().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected startTransaction to be a bool but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            request_info.start_transaction(start_transaction);
        }
        "readConcern" => {
            // Nested document — use scanner recursively for level extraction
            let doc_bytes = field.as_embedded_document_bytes().ok_or_else(|| {
                DocumentDBError::bad_value(format!(
                    "Expected readConcern to be a document but got element type 0x{:02X}",
                    field.element_type()
                ))
            })?;

            let mut level_str = "";
            bson_scanner::scan_document(doc_bytes, |inner_field| {
                if inner_field.name() == b"level" {
                    level_str = inner_field.as_str().unwrap_or("");
                }
                Ok(())
            })?;

            let read_concern = ReadConcern::from_str(level_str).unwrap_or_default();
            if read_concern == ReadConcern::Snapshot {
                request_info.isolation_level(IsolationLevel::RepeatableRead);
            }
            request_info.read_concern(read_concern);
        }
        "$readPreference" => {
            ReadPreference::parse(field.as_embedded_document_bytes())?;
        }
        "comment" => {
            if let Some(comment) = field.as_str() {
                request_info.comment(comment);
            }
        }
        "explain" => {
            request_info.explain(field.as_bool().unwrap_or(false));
        }
        key if collection_field.contains(&key) => {
            // Collection field extraction
            let collection = if collection_field[0] == "aggregate" {
                Some(if field.is_numeric() {
                    ""
                } else {
                    field.as_str().ok_or_else(|| {
                        DocumentDBError::bad_value(format!(
                            "Failed to parse aggregate key; expected string or numeric but got element type 0x{:02X}",
                            field.element_type()
                        ))
                    })?
                })
            } else {
                field.as_str()
            };

            request_info.collection(collection);
        }
        _ => {
            // Unknown fields are not part of the common request metadata.
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use bson::{doc, rawdoc, RawDocumentBuf};

    use crate::requests::Request;

    #[test]
    fn extract_common_ignores_unknown_fields_without_callback() {
        let request = Request::RawBuf(
            RequestType::Ping,
            rawdoc! {
                "ping": 1_i32,
                "$db": "admin",
                "ignored": "value",
            },
        );

        let info = request
            .extract_common()
            .expect("common fields should extract from document with ignored fields");

        assert_eq!(info.db().expect("$db should be present"), "admin");
    }

    #[test]
    fn extract_common_rejects_non_binary_lsid_id() {
        let request = Request::RawBuf(
            RequestType::Find,
            rawdoc! {
                "find": "orders",
                "$db": "testdb",
                "lsid": { "id": "not-binary" },
            },
        );

        request
            .extract_common()
            .expect_err("non-binary lsid.id should be rejected");
    }

    #[test]
    fn extract_common_rejects_duplicate_lsid_when_first_id_has_wrong_type() {
        let request = Request::RawBuf(
            RequestType::Find,
            rawdoc! {
                "find": "orders",
                "$db": "testdb",
                "lsid": {
                    "id": "not-binary",
                    "id": bson::Binary {
                        subtype: bson::spec::BinarySubtype::Uuid,
                        bytes: vec![1; 16],
                    },
                },
            },
        );

        request
            .extract_common()
            .expect_err("first lsid.id field controls type validation");
    }

    fn build_raw(doc: &bson::Document) -> RawDocumentBuf {
        RawDocumentBuf::from_document(doc)
            .expect("test document should serialize to RawDocumentBuf")
    }

    #[test]
    fn get_more_extracts_collection_name() {
        let doc = doc! {
            "getMore": 12345_i64,
            "collection": "myCollection",
            "$db": "testdb"
        };
        let request = Request::RawBuf(RequestType::GetMore, build_raw(&doc));
        let info = request
            .extract_common()
            .expect("extract_common should succeed");

        assert_eq!(
            info.collection().expect("collection should be present"),
            "myCollection"
        );
        assert_eq!(info.db().expect("db should be present"), "testdb");
    }

    #[test]
    fn get_more_without_collection_field_returns_error() {
        let doc = doc! {
            "getMore": 12345_i64,
            "$db": "testdb"
        };
        let request = Request::RawBuf(RequestType::GetMore, build_raw(&doc));
        let info = request
            .extract_common()
            .expect("extract_common should succeed");

        assert!(
            info.collection().is_err(),
            "collection should not be present when 'collection' field is missing"
        );
    }

    #[test]
    fn find_extracts_collection_from_command_key() {
        let doc = doc! {
            "find": "orders",
            "filter": {},
            "$db": "testdb"
        };
        let request = Request::RawBuf(RequestType::Find, build_raw(&doc));
        let info = request
            .extract_common()
            .expect("extract_common should succeed");

        assert_eq!(
            info.collection().expect("collection should be present"),
            "orders"
        );
    }

    #[test]
    fn extract_request_type_and_info_extracts_identity_and_common_fields() {
        let doc = rawdoc! {
            "find": "orders",
            "filter": {},
            "$db": "testdb",
            "maxTimeMS": 500_i32,
        };

        let (request_type, info) = extract_request_type_and_info_from_document(&doc)
            .expect("request metadata should parse");

        assert_eq!(request_type, RequestType::Find);
        assert_eq!(
            info.collection().expect("collection should be present"),
            "orders"
        );
        assert_eq!(info.db().expect("db should be present"), "testdb");
        assert_eq!(info.max_time_ms, Some(500));
    }

    #[test]
    fn extract_request_type_and_info_rejects_empty_document() {
        let doc = rawdoc! {};

        extract_request_type_and_info_from_document(&doc)
            .expect_err("empty command document should be rejected");
    }

    #[test]
    fn get_more_collection_field_is_mapped() {
        let request = Request::RawBuf(RequestType::GetMore, build_raw(&doc! {}));
        assert_eq!(
            collection_fields_for(request.request_type()),
            &["collection"]
        );
    }
}
