/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/process.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    explain,
    postgres::PgDataClient,
    processor::{
        constant, cursor, data_description, data_management, indexing, ismaster, roles, session,
        transaction, users,
    },
    requests::RequestType,
    responses::Response,
};

#[expect(
    clippy::too_many_lines,
    reason = "complex logic that would lose clarity if split"
)]
/// # Errors
///
/// Returns an error if the operation fails.
pub async fn process_request(
    request_context: &RequestContext<'_>,
    connection_context: &mut ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let dynamic_config = connection_context.dynamic_configuration();

    transaction::handle(request_context, connection_context, pg_data_client).await?;

    let result = match request_context.payload.request_type() {
        RequestType::Aggregate => {
            data_management::process_aggregate(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::BuildInfo => Ok(constant::process_build_info(&dynamic_config)),
        RequestType::CollStats => {
            data_management::process_coll_stats(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::Compact => {
            data_management::process_compact(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::ConnectionStatus => {
            if dynamic_config.enable_connection_status() {
                users::process_connection_status(
                    request_context,
                    connection_context,
                    pg_data_client,
                )
                .await
            } else {
                Ok(constant::process_connection_status())
            }
        }
        RequestType::Count => {
            data_management::process_count(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::Create => {
            data_description::process_create(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::CreateIndex | RequestType::CreateIndexes => {
            indexing::process_create_indexes(
                request_context,
                connection_context,
                &dynamic_config,
                pg_data_client,
            )
            .await
        }
        RequestType::Delete => {
            data_management::process_delete(
                request_context,
                connection_context,
                &dynamic_config,
                pg_data_client,
            )
            .await
        }
        RequestType::Distinct => {
            data_management::process_distinct(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::Drop => {
            data_description::process_drop_collection(
                request_context,
                connection_context,
                &dynamic_config,
                pg_data_client,
            )
            .await
        }
        RequestType::DropDatabase => {
            data_description::process_drop_database(
                request_context,
                connection_context,
                &dynamic_config,
                pg_data_client,
            )
            .await
        }
        RequestType::Explain => {
            explain::process_explain(request_context, None, connection_context, pg_data_client)
                .await
        }
        RequestType::Find => {
            data_management::process_find(request_context, connection_context, pg_data_client).await
        }
        RequestType::FindAndModify => {
            data_management::process_find_and_modify(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::GetCmdLineOpts => Ok(constant::process_get_cmd_line_opts()),
        RequestType::GetDefaultRWConcern => constant::process_get_rw_concern(request_context),
        RequestType::GetLog => Ok(constant::process_get_log()),
        RequestType::GetMore => {
            cursor::process_get_more(request_context, connection_context, pg_data_client).await
        }
        RequestType::Hello => ismaster::process(
            request_context,
            "isWritablePrimary",
            connection_context,
            &dynamic_config,
        ),
        RequestType::HostInfo => constant::process_host_info(),
        RequestType::Insert => {
            data_management::process_insert(
                request_context,
                connection_context,
                pg_data_client,
                dynamic_config.enable_write_procedures(),
                dynamic_config.enable_write_procedures_with_batch_commit(),
            )
            .await
        }
        RequestType::Isdbgrid => Ok(constant::process_is_db_grid(connection_context)),
        RequestType::IsMaster => ismaster::process(
            request_context,
            "ismaster",
            connection_context,
            &dynamic_config,
        ),
        RequestType::ListCollections => {
            data_management::process_list_collections(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::ListDatabases => {
            data_management::process_list_databases(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::ListIndexes => {
            indexing::process_list_indexes(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::Ping => Ok(constant::ok_response()),
        RequestType::SaslContinue | RequestType::SaslStart | RequestType::Logout => Err(
            DocumentDBError::internal_error("Command should have been handled by Auth".to_owned()),
        ),
        RequestType::Update => {
            data_management::process_update(
                request_context,
                connection_context,
                pg_data_client,
                dynamic_config.enable_write_procedures(),
                dynamic_config.enable_write_procedures_with_batch_commit(),
            )
            .await
        }
        RequestType::Validate => {
            data_management::process_validate(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::DropIndexes => {
            indexing::process_drop_indexes(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::ShardCollection => {
            data_description::process_shard_collection(
                request_context,
                connection_context,
                false,
                pg_data_client,
            )
            .await
        }
        RequestType::ReIndex => {
            indexing::process_reindex(request_context, connection_context, pg_data_client).await
        }
        RequestType::CurrentOp => {
            data_management::process_current_op(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::KillOp => {
            data_management::process_kill_op(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::CollMod => {
            data_description::process_coll_mod(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::GetParameter => {
            data_management::process_get_parameter(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::KillCursors => {
            cursor::process_kill_cursors(request_context, connection_context, pg_data_client).await
        }
        RequestType::DbStats => {
            data_management::process_db_stats(request_context, connection_context, pg_data_client)
                .await
        }
        RequestType::RenameCollection => {
            data_description::process_rename_collection(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::PrepareTransaction => constant::process_prepare_transaction(),
        RequestType::CommitTransaction => transaction::process_commit(connection_context).await,
        RequestType::AbortTransaction => transaction::process_abort(connection_context).await,
        RequestType::ListCommands => Ok(constant::list_commands()),
        RequestType::EndSessions | RequestType::KillSessions => {
            session::end_or_kill_sessions(request_context, connection_context, pg_data_client).await
        }
        RequestType::ReshardCollection => {
            data_description::process_shard_collection(
                request_context,
                connection_context,
                true,
                pg_data_client,
            )
            .await
        }
        RequestType::WhatsMyUri => Ok(constant::process_whats_my_uri()),
        RequestType::CreateUser => {
            users::process_create_user(request_context, connection_context, pg_data_client).await
        }
        RequestType::DropUser => {
            users::process_drop_user(request_context, connection_context, pg_data_client).await
        }
        RequestType::UpdateUser => {
            users::process_update_user(request_context, connection_context, pg_data_client).await
        }
        RequestType::UsersInfo => {
            users::process_users_info(request_context, connection_context, pg_data_client).await
        }
        RequestType::CreateRole => {
            roles::process_create_role(request_context, connection_context, pg_data_client).await
        }
        RequestType::UpdateRole => {
            roles::process_update_role(request_context, connection_context, pg_data_client).await
        }
        RequestType::DropRole => {
            roles::process_drop_role(request_context, connection_context, pg_data_client).await
        }
        RequestType::RolesInfo => {
            roles::process_roles_info(request_context, connection_context, pg_data_client).await
        }
        RequestType::UnshardCollection => {
            data_description::process_unshard_collection(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::GetShardMap => {
            data_description::process_get_shard_map(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::ListShards => {
            data_description::process_list_shards(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::BalancerStart => {
            data_description::process_balancer_start(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::BalancerStatus => {
            data_description::process_balancer_status(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::BalancerStop => {
            data_description::process_balancer_stop(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        RequestType::MoveCollection => {
            data_description::process_move_collection(
                request_context,
                connection_context,
                pg_data_client,
            )
            .await
        }
        _ => Err(DocumentDBError::documentdb_error(
            ErrorCode::CommandNotSupported,
            format!(
                "Command '{}' not supported.",
                request_context.payload.request_type().to_command_str()
            ),
        )),
    };

    if connection_context.transaction.is_some() {
        match result {
            // In the case of write conflict, we need to abort the transaction.
            Err(DocumentDBError::DocumentDBError(ErrorCode::WriteConflict, _, _, _)) => {
                transaction::process_abort(connection_context).await?;
            }
            // In the case of failures with aggregate/find, we need to abort the transaction.
            Err(_)
                if request_context.payload.request_type() == RequestType::Find
                    || request_context.payload.request_type() == RequestType::Aggregate =>
            {
                transaction::process_abort(connection_context).await?;
            }
            _ => {}
        }
    }

    result
}
