/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/data_description.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::rawdoc;

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    protocol::{self, OK_SUCCEEDED},
    responses::{RawResponse, Response},
};

pub async fn process_coll_mod(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_coll_mod(request_context, connection_context)
        .await
}

pub async fn process_create(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_create_collection(request_context, connection_context)
        .await
}

pub async fn process_drop_database(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    dynamic_config: &Arc<dyn DynamicConfiguration>,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request_info = request_context.info;

    let db = request_info.db()?.to_owned();

    // Invalidate cursors
    connection_context
        .service_context
        .cursor_store()
        .invalidate_cursors_by_database(&db);

    // Nested transactions not allowed when database is in read-only mode
    let is_read_only_for_disk_full =
        dynamic_config.is_read_only_for_disk_full() && connection_context.transaction.is_none();

    if is_read_only_for_disk_full {
        pg_data_client
            .execute_drop_database_when_readonly(request_context, db.as_str(), connection_context)
            .await?;
    } else {
        pg_data_client
            .execute_drop_database(request_context, db.as_str(), connection_context)
            .await?;
    }

    Ok(Response::Raw(RawResponse(rawdoc! {
        "ok": OK_SUCCEEDED,
        "dropped": db,
    })))
}

pub async fn process_drop_collection(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    dynamic_config: &Arc<dyn DynamicConfiguration>,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request_info = request_context.info;

    let coll = request_info.collection()?.to_owned();
    let coll_str = coll.as_str();
    let db = request_info.db()?.to_owned();
    let db_str = db.as_str();

    // Invalidate cursors
    connection_context
        .service_context
        .cursor_store()
        .invalidate_cursors_by_collection(db_str, coll_str);

    // Nested transactions not allowed when database is in read-only mode
    let is_read_only_for_disk_full =
        dynamic_config.is_read_only_for_disk_full() && connection_context.transaction.is_none();

    if is_read_only_for_disk_full {
        pg_data_client
            .execute_drop_collection_when_readonly(
                request_context,
                db_str,
                coll_str,
                connection_context,
            )
            .await?;
    } else {
        pg_data_client
            .execute_drop_collection(request_context, db_str, coll_str, connection_context)
            .await?;
    }

    Ok(Response::Raw(RawResponse(rawdoc! {
        "ok": OK_SUCCEEDED,
        "dropped": coll,
    })))
}

pub async fn process_rename_collection(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_rename_collection(request_context, connection_context)
        .await?;
    Ok(Response::ok())
}

pub async fn process_shard_collection(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    reshard: bool,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let collection_path = request_context.info.collection()?.to_owned();
    let (db, collection) =
        protocol::extract_database_and_collection_names(collection_path.as_str())?;
    let key = request_context
        .payload
        .document()
        .get_document("key")
        .map_err(DocumentDBError::parse_failure())?;

    pg_data_client
        .execute_shard_collection(
            request_context,
            db,
            collection,
            key,
            reshard,
            connection_context,
        )
        .await?;

    Ok(Response::ok())
}

pub async fn process_unshard_collection(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_unshard_collection(request_context, connection_context)
        .await?;

    Ok(Response::ok())
}

pub async fn process_get_shard_map(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_get_shard_map(request_context, connection_context)
        .await
}

pub async fn process_list_shards(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_list_shards(request_context, connection_context)
        .await
}

pub async fn process_balancer_start(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_balancer_start(request_context, connection_context)
        .await
}

pub async fn process_balancer_status(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_balancer_status(request_context, connection_context)
        .await
}

pub async fn process_balancer_stop(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_balancer_stop(request_context, connection_context)
        .await
}

pub async fn process_move_collection(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_move_collection(request_context, connection_context)
        .await
}
