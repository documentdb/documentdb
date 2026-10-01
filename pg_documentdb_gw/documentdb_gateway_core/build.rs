/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/build.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{env, error::Error, fs, path::PathBuf};

use proc_macro2::{Span, TokenStream};
use quote::{format_ident, quote};
use syn::LitInt;

const ERROR_MAPPINGS: &str = include_str!("../include/all_error_mappings_oss_generated.csv");
const POSTGRES_ERRORS: &str = include_str!("../documentdb_macros/postgres_errors.csv");

fn main() -> Result<(), Box<dyn Error>> {
    // Consumers with an extended tokio-postgres API opt in via this cfg.
    println!("cargo::rustc-check-cfg=cfg(pg_buffer_size)");
    // Cargo resolves these paths relative to this package, not the invoking workspace.
    println!("cargo::rerun-if-changed=../include/all_error_mappings_oss_generated.csv");
    println!("cargo::rerun-if-changed=../documentdb_macros/postgres_errors.csv");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").ok_or("Cargo did not set OUT_DIR")?);
    let (error_codes, int_mapping) = generate_error_mappings()?;
    for (name, tokens) in [
        ("error_code_enum.rs", error_codes),
        ("int_error_mapping.rs", int_mapping),
        (
            "postgres_error_logging_mapping.rs",
            generate_postgres_error_logging_mapping()?,
        ),
    ] {
        let path = out_dir.join(name);
        fs::write(&path, tokens.to_string())
            .map_err(|error| format!("Failed to write {}: {error}", path.display()))?;
    }
    Ok(())
}

fn generate_error_mappings() -> Result<(TokenStream, TokenStream), Box<dyn Error>> {
    let mut names = Vec::new();
    let mut states = Vec::new();
    let mut codes = Vec::new();

    for (index, line) in ERROR_MAPPINGS.lines().skip(1).enumerate() {
        let fields: Vec<_> = line.split(',').map(str::trim).collect();

        let [name, state, code] = fields.as_slice() else {
            return Err(format!("Invalid error mapping at line {}", index + 2).into());
        };

        let code = code
            .parse::<i32>()
            .map_err(|error| format!("Invalid error code at line {}: {error}", index + 2))?;

        names.push(format_ident!("{name}"));
        states.push(*state);

        let literal = format_with_underscores(code);
        codes.push(LitInt::new(&literal, Span::call_site()));
    }

    let error_codes = quote! {
        /// Error codes supported by the wire protocol.
        #[derive(Debug, Clone, Copy, strum_macros::AsRefStr, strum_macros::Display, PartialEq, Eq)]
        pub enum ErrorCode {
            #(#names = #codes,)*
        }

        impl ErrorCode {
            /// Returns the known error code, or `None` for an unknown value.
            #[must_use]
            pub const fn from_i32(n: i32) -> Option<Self> {
                match n {
                    #(#codes => Some(Self::#names),)*
                    _ => None,
                }
            }

            /// Returns the known error code, or `None` for an unknown or out-of-range value.
            #[must_use]
            pub fn from_u32(n: u32) -> Option<Self> {
                i32::try_from(n).ok().and_then(Self::from_i32)
            }
        }
    };

    let int_mapping = quote! {
        match state.code() {
            #(#states => Some(#codes),)*
            _ => None,
        }
    };

    Ok((error_codes, int_mapping))
}

fn generate_postgres_error_logging_mapping() -> Result<TokenStream, Box<dyn Error>> {
    let mut states = Vec::new();

    for (index, line) in POSTGRES_ERRORS.lines().skip(1).enumerate() {
        let fields: Vec<_> = line.split(',').map(str::trim).collect();

        let [_, state, _, log, ""] = fields.as_slice() else {
            return Err(format!("Invalid PostgreSQL error mapping at line {}", index + 2).into());
        };

        let should_log = log
            .parse::<bool>()
            .map_err(|error| format!("Invalid logging flag at line {}: {error}", index + 2))?;

        if should_log {
            states.push(*state);
        }
    }

    Ok(quote! {
        /// Whether this `PostgreSQL` error requires additional diagnostic logging.
        #[must_use]
        pub fn should_log_on_postgres_error(state: &SqlState) -> bool {
            [#(#states),*].contains(&state.code())
        }
    })
}

fn format_with_underscores(num: i32) -> String {
    let s = num.to_string();
    let mut result = String::new();

    for (i, ch) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 && ch != '-' {
            result.push('_');
        }
        result.push(ch);
    }

    result.chars().rev().collect()
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use proc_macro2::Span;
    use syn::LitInt;

    #[test]
    fn formats_signed_error_code_literals() -> Result<(), Box<dyn Error>> {
        for (num, expected) in [
            (0, "0"),
            (12, "12"),
            (123, "123"),
            (1_234, "1_234"),
            (12_345, "12_345"),
            (123_456, "123_456"),
            (100_000_000, "100_000_000"),
            (-123, "-123"),
            (-1_234, "-1_234"),
            (i32::MIN, "-2_147_483_648"),
            (i32::MAX, "2_147_483_647"),
        ] {
            let formatted = crate::format_with_underscores(num);
            assert_eq!(formatted, expected);
            assert_eq!(
                LitInt::new(&formatted, Span::call_site()).base10_parse::<i32>()?,
                num
            );
        }
        Ok(())
    }
}
