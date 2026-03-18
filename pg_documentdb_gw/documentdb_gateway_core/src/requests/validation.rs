/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/validation.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode, Result},
    requests::{read_concern::ReadConcern, Request, RequestInfo, RequestType},
};

/// Validates that the given request is consistent with the current connection and
/// transaction state.
///
/// # Errors
/// Returns an error if the request violates transaction or session constraints.
pub fn validate_request(
    connection_context: &ConnectionContext,
    request_info: &RequestInfo,
    request: &Request<'_>,
) -> Result<()> {
    let Some(request_transaction_info) = request_info.transaction_info.as_ref() else {
        return Ok(());
    };

    if request_transaction_info.auto_commit {
        if request_info.session_id.is_none() {
            return Err(DocumentDBError::documentdb_error(
                    ErrorCode::NotARetryableWriteCommand,
                    "txnNumber may only be provided for multi-document transactions and retryable write commands. autocommit:false was not provided, and command is not a retryable write command.".to_owned(),
                ));
        }

        return Ok(());
    }

    let request_type = request.request_type();

    if request_type.is_blocked_in_transaction() {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::OperationNotSupportedInTransaction,
            format!("Cannot run '{request_type}' in a multi-document transaction."),
        ));
    }

    if (matches!(request_type, RequestType::KillCursors)
        && request_transaction_info.start_transaction
        && !request_transaction_info.auto_commit)
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::OperationNotSupportedInTransaction,
            "Cannot run command KillCursors at the start of a transaction".to_owned(),
        ));
    }

    if matches!(
        request_type,
        RequestType::Aggregate
            | RequestType::FindAndModify
            | RequestType::Update
            | RequestType::Insert
            | RequestType::Count
            | RequestType::Distinct
            | RequestType::Find
            | RequestType::GetMore
    ) {
        if matches!(request.db()?, "config" | "admin" | "local") {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::OperationNotSupportedInTransaction,
                format!(
                    "Cannot perform data operation against database {} inside a transaction",
                    request.db()?
                ),
            ));
        }

        let collection: &str = match request_info.collection() {
            Ok(c) if !c.is_empty() => c,
            _ => "",
        };

        if collection == "system.profile" {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::OperationNotSupportedInTransaction,
                "Cannot run command against system collections in transaction.".to_owned(),
            ));
        }

        if collection.starts_with("system.") {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::Location51071,
                "Cannot run command against system views in transaction.".to_owned(),
            ));
        }
    }

    if !request_transaction_info.start_transaction
        && *request_info.read_concern() != ReadConcern::Unspecified
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::InvalidOptions,
            "Read concern cannot be defined after transaction has started".to_owned(),
        ));
    }

    // you need a dynamic_configuration, so would split the parsing logic in 2 stages,
    // one is parsing the request and extract the transaction information,
    // the other is validating the transaction information and create the transaction if necessary. This is because some of the validation requires dynamic configuration, which is only accessible in the processing stage.
    if request_info.read_concern() == &ReadConcern::Snapshot
        && !(connection_context
            .service_context
            .dynamic_configuration()
            .allow_transaction_snapshot())
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::CommandNotSupported,
            format!(
                "'{:?}' read concern is not supported",
                &ReadConcern::Snapshot
            ),
        ));
    }

    if matches!(
        request_info.read_concern(),
        ReadConcern::Available | ReadConcern::Linearizable
    ) {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::CommandNotSupported,
            format!(
                "'{:?}' read concern is not supported",
                request_info.read_concern()
            ),
        ));
    }
    Ok(())
}
