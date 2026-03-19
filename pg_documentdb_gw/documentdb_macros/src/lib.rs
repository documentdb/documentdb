/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_macros/src/lib.rs
 *
 *-------------------------------------------------------------------------
 */

extern crate proc_macro;

use std::fmt::Write;

use proc_macro::TokenStream;

/// Generates the `from_known_external_error_code` function that maps SQL error
/// states to integer error codes based on the OSS error-mapping CSV.
///
/// # Panics
///
/// Panics if the error-mapping CSV file cannot be opened, read, or parsed.
/// This is intentional — proc macros run at compile time and a missing or
/// malformed CSV is an unrecoverable build error.
#[expect(
    clippy::unwrap_used,
    reason = "proc macro — compile-time panic is the correct failure mode"
)]
#[proc_macro]
pub fn documentdb_int_error_mapping(_item: TokenStream) -> TokenStream {
    let mut result = String::new();
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../pg_documentdb_core/include/utils/all_error_mappings_oss_generated.csv");
    let csv = std::fs::File::open(path).unwrap();
    let reader = std::io::BufReader::new(csv);

    result += "pub fn from_known_external_error_code(state: &SqlState) -> Option<i32> {
                match state.code() {";
    for line in std::io::BufRead::lines(reader).skip(1) {
        let line = line.unwrap();
        let parts: Vec<&str> = line.split(',').collect();

        write!(result, "\"{}\" => Some({}),", parts[1], parts[2]).unwrap();
    }
    result += "_ => None
    }
    }";
    result.parse().unwrap()
}

/// Generates the `ErrorCode` enum with `from_i32` and `from_u32` conversion
/// methods from the OSS error-mapping CSV.
///
/// The gateway deals with known errors defined in two files — one in the
/// backend and one in the gateway — to maintain a logical separation. This
/// macro produces a unified enum so that both sets of error codes are
/// available in Rust code.
///
/// # Panics
///
/// Panics if the error-mapping CSV file cannot be read or parsed.
/// This is intentional — proc macros run at compile time and a missing or
/// malformed CSV is an unrecoverable build error.
#[expect(
    clippy::unwrap_used,
    reason = "proc macro — compile-time panic is the correct failure mode"
)]
#[expect(
    clippy::expect_used,
    reason = "proc macro — compile-time panic is the correct failure mode"
)]
#[proc_macro]
pub fn documentdb_error_code_enum(_item: TokenStream) -> TokenStream {
    let external_error_mapping_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../pg_documentdb_core/include/utils/all_error_mappings_oss_generated.csv");

    let csv = std::fs::read_to_string(&external_error_mapping_path)
        .expect("Could not read external_error_mapping.csv");
    let mut error_code_enum_entries = String::new();
    error_code_enum_entries += "#[derive(Debug, Clone, Copy, strum_macros::AsRefStr)]
        pub enum ErrorCode {";

    let mut from_primitive = String::new();
    from_primitive += "impl ErrorCode {
             pub fn from_i32(n: i32) -> Option<Self> {
                 match n {";

    for external_error in csv.lines().skip(1) {
        let parts: Vec<&str> = external_error.split(',').collect();
        let name = parts[0].trim();
        let code = parts[2].trim();
        write!(error_code_enum_entries, "{name} = {code},").unwrap();
        write!(from_primitive, "{code} => Some(ErrorCode::{name}),").unwrap();
    }

    error_code_enum_entries += "
    }
    ";

    from_primitive += "_ => None,
        }
    }

    pub fn from_u32(n: u32) -> Option<Self> {
        Self::from_i32(n as i32)
    }
}";

    error_code_enum_entries += &from_primitive;
    error_code_enum_entries.parse().unwrap()
}

/// # Panics
///
/// Panics if the error-mapping CSV file cannot be read or parsed.
/// This is intentional — proc macros run at compile time and a missing or
/// malformed CSV is an unrecoverable build error.
#[expect(
    clippy::unwrap_used,
    reason = "proc macro — compile-time panic is the correct failure mode"
)]
#[proc_macro]
pub fn documentdb_extensive_log_postgres_errors(_item: TokenStream) -> TokenStream {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("postgres_errors.csv");
    let csv = std::fs::File::open(&path)
        .unwrap_or_else(|_| panic!("Could not open file: \"{}\"", path.display()));
    let reader = std::io::BufReader::new(csv);

    let mut result = String::new();
    result += "pub fn should_log_on_postgres_error(state: &SqlState) -> bool {
                match state.code() {";

    for (index, line) in std::io::BufRead::lines(reader).skip(1).enumerate() {
        let line = line.unwrap_or_else(|_| {
            panic!(
                "Could not read line {} in file: {}",
                index + 2,
                path.display()
            )
        });
        let parts: Vec<&str> = line.split(',').collect();
        let code = parts[1].trim();
        let should_log_debug = parts[3].trim();
        write!(result, "\"{code}\" => {should_log_debug},").unwrap();
    }

    result += "_ => false
    }
    }";
    result.parse().unwrap()
}
