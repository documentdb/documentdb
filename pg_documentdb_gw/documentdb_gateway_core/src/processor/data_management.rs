/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/data_management.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::RawBsonRef;

use crate::{
    bson::{convert_to_bool, decimal128_to_f64},
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    responses::{PgResponse, Response},
};

pub async fn process_delete(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    dynamic_config: &Arc<dyn DynamicConfiguration>,
    pg_data_client: &impl PgDataClient,
    enable_write_procedures: bool,
) -> Result<Response> {
    // Nested transactions not allowed when database is in read-only mode
    let is_read_only_for_disk_full =
        dynamic_config.is_read_only_for_disk_full() && connection_context.transaction.is_none();

    let delete_rows = if is_read_only_for_disk_full {
        pg_data_client
            .execute_delete_when_readonly(request_context, connection_context)
            .await?
    } else {
        pg_data_client
            .execute_delete(request_context, connection_context, enable_write_procedures)
            .await?
    };

    PgResponse::new(delete_rows)
        .transform_write_errors(connection_context, request_context.activity_id)
}

pub async fn process_find(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_find(request_context, connection_context)
        .await
}

pub async fn process_insert(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    enable_write_procedures: bool,
    enable_write_procedures_with_batch_commit: bool,
) -> Result<Response> {
    let insert_rows = pg_data_client
        .execute_insert(
            request_context,
            connection_context,
            enable_write_procedures,
            enable_write_procedures_with_batch_commit,
        )
        .await?;

    PgResponse::new(insert_rows)
        .transform_write_errors(connection_context, request_context.activity_id)
}

pub async fn process_aggregate(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_aggregate(request_context, connection_context)
        .await
}

pub async fn process_update(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    enable_write_procedures: bool,
    enable_write_procedures_with_batch_commit: bool,
) -> Result<Response> {
    let update_rows = pg_data_client
        .execute_update(
            request_context,
            connection_context,
            enable_write_procedures,
            enable_write_procedures_with_batch_commit,
        )
        .await?;

    PgResponse::new(update_rows)
        .transform_write_errors(connection_context, request_context.activity_id)
}

pub async fn process_list_databases(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_list_databases(request_context, connection_context)
        .await
}

pub async fn process_list_collections(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_list_collections(request_context, connection_context)
        .await
}

pub async fn process_validate(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_validate(request_context, connection_context)
        .await
}

pub async fn process_find_and_modify(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_find_and_modify(request_context, connection_context)
        .await
}

pub async fn process_distinct(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_distinct_query(request_context, connection_context)
        .await
}

pub async fn process_count(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    // we need to ensure that the collection is correctly set up before we can execute the count query
    request_context.request().collection()?;

    pg_data_client
        .execute_count_query(request_context, connection_context)
        .await
}

#[expect(
    clippy::cast_precision_loss,
    reason = "precision loss acceptable for scale"
)]
fn convert_to_scale(scale: RawBsonRef) -> Result<f64> {
    match scale {
        RawBsonRef::Double(d) => Ok(d),
        RawBsonRef::Int32(i) => Ok(f64::from(i)),
        RawBsonRef::Int64(i) => Ok(i as f64),
        RawBsonRef::Decimal128(d) => decimal128_to_f64(d).ok_or_else(|| {
            DocumentDBError::documentdb_error(
                ErrorCode::TypeMismatch,
                "Unexpected value for scale".to_owned(),
            )
        }),
        RawBsonRef::Undefined | RawBsonRef::Null => Ok(1.0),
        other => Err(DocumentDBError::documentdb_error(
            ErrorCode::TypeMismatch,
            format!(
                "Unexpected bson type for scale: {:#?}",
                other.element_type()
            ),
        )),
    }
}

pub async fn process_coll_stats(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    // allow floats and ints, the backend will truncate
    let scale = if let Some(scale) = request_context.request().document().get("scale")? {
        convert_to_scale(scale)?
    } else {
        1.0
    };

    pg_data_client
        .execute_coll_stats(request_context, scale, connection_context)
        .await
}

pub async fn process_db_stats(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    // allow floats and ints, the backend will truncate
    let scale = if let Some(scale) = request_context.request().document().get("scale")? {
        convert_to_scale(scale)?
    } else {
        1.0
    };

    pg_data_client
        .execute_db_stats(request_context, scale, connection_context)
        .await
}

pub async fn process_current_op(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_current_op(request_context, connection_context)
        .await
}

pub async fn process_kill_op(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.request();

    let mut operation_id: Option<String> = None;
    request.extract_fields(|key, value| {
        if key == "op" {
            // The "op" field contains the operation ID to kill
            if let Some(op_str) = value.as_str() {
                operation_id = Some(op_str.to_owned());
            } else {
                return Err(DocumentDBError::type_mismatch(format!(
                    "Expected \"op\" field to be a string, but got {:?}",
                    value.element_type()
                )));
            }
        }
        Ok(())
    })?;

    let op_id = operation_id
        .ok_or_else(|| DocumentDBError::bad_value("Did not provide \"op\" field".to_owned()))?;

    // Validate that the command is run against the admin database
    if request.db() != "admin" {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            "killOp may only be run against the admin database.".to_owned(),
        ));
    }

    pg_data_client
        .execute_kill_op(request_context, &op_id, connection_context)
        .await
}

async fn get_parameter(
    connection_context: &ConnectionContext,
    request_context: &RequestContext<'_>,
    all: bool,
    show_details: bool,
    params: Vec<String>,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_get_parameter(
            request_context,
            all,
            show_details,
            params,
            connection_context,
        )
        .await
}

pub async fn process_get_parameter(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.request();

    let mut all_parameters = false;
    let mut show_details = false;
    let mut star = false;
    let mut params = Vec::new();
    request.extract_fields(|k, v| {
        match k {
            "getParameter" => {
                if v.as_str().is_some_and(|s| s == "*") {
                    star = true;
                } else if let Some(doc) = v.as_document() {
                    for pair in doc {
                        let (k, v) = pair?;
                        match k {
                            "allParameters" => {
                                all_parameters =
                                    convert_to_bool(v).ok_or(DocumentDBError::type_mismatch(
                                        "allParameters should be a bool".to_owned(),
                                    ))?;
                            }
                            "showDetails" => {
                                show_details =
                                    convert_to_bool(v).ok_or(DocumentDBError::type_mismatch(
                                        "showDetails should be convertible to a bool".to_owned(),
                                    ))?;
                            }
                            "setAt" if !matches!(v, RawBsonRef::String(_) | RawBsonRef::Null) => {
                                return Err(DocumentDBError::type_mismatch(
                                    "setAt should be a string".to_owned(),
                                ));
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => params.push(k.to_owned()),
        }
        Ok(())
    })?;
    if request.db() != "admin" {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            "getParameter may only be run against the admin database.".to_owned(),
        ));
    }

    if star {
        return get_parameter(
            connection_context,
            request_context,
            true,
            false,
            vec![],
            pg_data_client,
        )
        .await;
    }

    get_parameter(
        connection_context,
        request_context,
        all_parameters,
        show_details,
        params,
        pg_data_client,
    )
    .await
}

pub async fn process_compact(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    pg_data_client
        .execute_compact(request_context, connection_context)
        .await
}

#[cfg(test)]
mod tests {
    use bson::Decimal128;

    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn convert_to_scale_accepts_numeric_and_decimal() {
        assert!(approx(
            convert_to_scale(RawBsonRef::Double(2.5)).expect("double accepted"),
            2.5
        ));
        assert!(approx(
            convert_to_scale(RawBsonRef::Int32(7)).expect("int32 accepted"),
            7.0
        ));
        assert!(approx(
            convert_to_scale(RawBsonRef::Int64(1024)).expect("int64 accepted"),
            1024.0
        ));

        let dec = "1024".parse::<Decimal128>().expect("valid decimal");
        assert!(approx(
            convert_to_scale(RawBsonRef::Decimal128(dec)).expect("decimal accepted"),
            1024.0
        ));
    }

    #[test]
    fn convert_to_scale_defaults_null_and_undefined_to_one() {
        assert!(approx(
            convert_to_scale(RawBsonRef::Null).expect("null accepted"),
            1.0
        ));
        assert!(approx(
            convert_to_scale(RawBsonRef::Undefined).expect("undefined accepted"),
            1.0
        ));
    }

    #[test]
    fn convert_to_scale_rejects_non_numeric_types() {
        convert_to_scale(RawBsonRef::String("x")).expect_err("string rejected");
        convert_to_scale(RawBsonRef::Boolean(true)).expect_err("bool rejected");
    }
}
