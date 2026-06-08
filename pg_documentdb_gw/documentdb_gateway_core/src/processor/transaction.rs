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
pub async fn handle(
    request_context: &RequestContext<'_>,
    connection_context: &mut ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<()> {
    let (request, request_info, _) = request_context.get_components();

    connection_context.transaction = None;

    if let Some(request_transaction_info) = &request_info.transaction_info {
        if request_transaction_info.auto_commit {
            return Ok(());
        }

        let caller = connection_context.auth_state.principal()?;

        let lsid = request_info
            .lsid
            .clone()
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
            return match (request.request_type(), &e) {
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
    Ok(Response::ok())
}

pub async fn process_abort(context: &ConnectionContext, activity_id: &str) -> Result<Response> {
    let (lsid, _) = context
        .transaction
        .as_ref()
        .ok_or(DocumentDBError::internal_error(
            "Transaction information was not populated for abort.".to_owned(),
        ))?;

    let caller = context.auth_state.principal()?;
    let store = context.service_context.transaction_store();
    let is_replica_cluster = context.dynamic_configuration().is_replica_cluster();

    store
        .abort(lsid, caller)
        .await
        .map_err(|e| map_transaction_error(e, is_replica_cluster, activity_id))?;
    Ok(Response::ok())
}
