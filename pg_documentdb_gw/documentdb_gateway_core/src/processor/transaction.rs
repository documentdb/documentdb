/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/transaction.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    context::{map_transaction_error, ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    requests::RequestType,
    responses::Response,
};

// Create the transaction if required, and populate the context information with the transaction info
#[cfg_attr(
    feature = "request-tracing",
    tracing::instrument(name = "postgres.transaction", skip_all)
)]
pub async fn handle(
    request_context: &RequestContext<'_>,
    connection_context: &mut ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<()> {
    let request = request_context.request();

    connection_context.transaction = None;

    if let Some(request_transaction_info) = request.transaction_info() {
        if request_transaction_info.auto_commit {
            return Ok(());
        }

        let caller = connection_context.auth_state.principal()?;

        let lsid = request
            .lsid()
            .cloned()
            .ok_or(DocumentDBError::internal_error(
                "Session Id is missing. Transactions must be associated with a session.".to_owned(),
            ))?;

        let store = connection_context.service_context.transaction_store();
        let transaction_result = store
            .create(
                connection_context,
                request_transaction_info,
                lsid.clone(),
                pg_data_client,
                caller,
                request_context.activity_id,
            )
            .await;

        if let Err(e) = transaction_result {
            return match (request_context.request_type(), &e) {
                // Especially allow the transaction to remain unfilled if it is committing a committed transaction
                (RequestType::CommitTransaction, error)
                    if error.error_code() == ErrorCode::TransactionCommitted =>
                {
                    Ok(())
                }
                _ => Err(e),
            };
        }

        connection_context.transaction = Some((lsid, request_transaction_info.transaction_number));
    }

    // A commitTransaction/abortTransaction with no resolvable transaction number
    // never entered the block above, so there is no transaction to act on. The
    // documented semantics require reporting NoSuchTransaction rather than
    // silently succeeding (commit) or failing internally (abort). The idempotent
    // "commit an already-committed transaction" retry carries a transaction
    // number and returns early above, so it is unaffected.
    if connection_context.transaction.is_none()
        && matches!(
            request_context.request_type(),
            RequestType::CommitTransaction | RequestType::AbortTransaction
        )
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::NoSuchTransaction,
            "No transaction is active for this session".to_owned(),
        ));
    }

    Ok(())
}

pub async fn process_commit(context: &ConnectionContext, activity_id: &str) -> Result<Response> {
    if let Some((lsid, _)) = context.transaction.as_ref() {
        let store = context.service_context.transaction_store();
        let caller = context.auth_state.principal()?;
        let is_replica_cluster = context.dynamic_configuration().is_replica_cluster();

        store
            .commit(lsid, caller)
            .await
            .map_err(|e| map_transaction_error(e, is_replica_cluster, activity_id))?;
    }
    // Reaching here without a transaction means `handle` swallowed the
    // already-committed case (an idempotent commit retry) to leave the context
    // transaction unset; that retry must still report success. A commit with no
    // resolvable transaction is rejected earlier in `handle` with
    // NoSuchTransaction, so it never reaches this no-op.
    Ok(Response::ok())
}

pub async fn process_abort(context: &ConnectionContext, activity_id: &str) -> Result<Response> {
    let Some((lsid, _)) = context.transaction.as_ref() else {
        // An abortTransaction that arrives without an active transaction context
        // (for example a session that never began a transaction, so no
        // transaction number resolves) leaves the context transaction unset.
        // Surface the documented NoSuchTransaction error instead of an internal
        // error.
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::NoSuchTransaction,
            "No transaction is active for this session".to_owned(),
        ));
    };

    let caller = context.auth_state.principal()?;
    let store = context.service_context.transaction_store();
    let is_replica_cluster = context.dynamic_configuration().is_replica_cluster();

    store
        .abort(lsid, caller)
        .await
        .map_err(|e| map_transaction_error(e, is_replica_cluster, activity_id))?;
    Ok(Response::ok())
}
