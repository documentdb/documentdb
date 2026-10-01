/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/tests/error_mappings.rs
 *
 *-------------------------------------------------------------------------
 */

use std::error::Error;

use documentdb_gateway_core::{
    error::{self, ErrorCode},
    responses,
};
use tokio_postgres::error::SqlState;

#[test]
fn generated_mappings_match_every_csv_row() -> Result<(), Box<dyn Error>> {
    for line in include_str!("../../include/all_error_mappings_oss_generated.csv")
        .lines()
        .skip(1)
    {
        let fields: Vec<_> = line.split(',').collect();
        let code = fields[2].parse::<i32>()?;
        let error_code = ErrorCode::from_i32(code).ok_or("Missing error code")?;
        assert_eq!(error_code as i32, code);
        assert_eq!(error_code.as_ref(), fields[0]);
        assert_eq!(error_code.to_string(), fields[0]);
        assert_eq!(ErrorCode::from_u32(u32::try_from(code)?), Some(error_code));
        assert_eq!(
            responses::from_known_external_error_code(&SqlState::from_code(fields[1])),
            Some(code)
        );
    }
    for line in include_str!("../../documentdb_macros/postgres_errors.csv")
        .lines()
        .skip(1)
    {
        let fields: Vec<_> = line.split(',').collect();
        assert_eq!(
            error::should_log_on_postgres_error(&SqlState::from_code(fields[1])),
            fields[3].parse::<bool>()?
        );
    }
    for code in [i32::MIN, -1, 0, i32::MAX] {
        assert_eq!(ErrorCode::from_i32(code), None);
    }
    for code in [0, u32::try_from(i32::MAX)? + 1, u32::MAX] {
        assert_eq!(ErrorCode::from_u32(code), None);
    }
    let unknown = SqlState::from_code("ZZZZZ");
    assert_eq!(responses::from_known_external_error_code(&unknown), None);
    assert!(!error::should_log_on_postgres_error(&unknown));
    Ok(())
}
