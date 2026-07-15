/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/get_parameter.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::missing_panics_doc,
    reason = "Test helper functions - panics are expected test failures"
)]
#![expect(
    clippy::missing_errors_doc,
    reason = "Test helper functions - error conditions are self-explanatory"
)]
#![expect(
    clippy::unwrap_used,
    reason = "Test helper functions - unwrap failures indicate test failures"
)]
#![expect(
    clippy::expect_used,
    reason = "Test helper functions - expect failures indicate test failures"
)]
#![expect(
    clippy::float_cmp,
    reason = "Test assertions compare exact float values returned from database"
)]

use bson::doc;
use mongodb::{error::Error, Client};

use crate::utils::commands;

/// The `featureCompatibilityVersion` the gateway reports mirrors its configured
/// server version, so accept any of the versions the gateway knows about.
const KNOWN_FCV_VERSIONS: &[&str] = &["4.2", "5.0", "6.0", "7.0", "8.0"];

pub async fn validate_get_parameter_fcv(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");
    let result = db
        .run_command(doc! { "getParameter": 1, "featureCompatibilityVersion": 1 })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    let fcv = result
        .get_document("featureCompatibilityVersion")
        .expect("response must contain featureCompatibilityVersion");
    let version = fcv.get_str("version").unwrap();
    assert!(
        KNOWN_FCV_VERSIONS.contains(&version),
        "unexpected featureCompatibilityVersion.version: {version}"
    );

    Ok(())
}

pub async fn validate_get_parameter_star(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");
    let result = db.run_command(doc! { "getParameter": "*" }).await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(
        result.get_document("featureCompatibilityVersion").is_ok(),
        "the '*' form must include featureCompatibilityVersion"
    );

    Ok(())
}

pub async fn validate_get_parameter_all_parameters(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");
    let result = db
        .run_command(doc! { "getParameter": 1, "allParameters": true })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(
        result.get_document("featureCompatibilityVersion").is_ok(),
        "the allParameters form must include featureCompatibilityVersion"
    );

    Ok(())
}

pub async fn validate_get_parameter_show_details(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");
    let result = db
        .run_command(doc! {
            "getParameter": doc! { "showDetails": true },
            "featureCompatibilityVersion": 1,
        })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    let details = result
        .get_document("featureCompatibilityVersion")
        .expect("response must contain featureCompatibilityVersion");
    // With showDetails the value is wrapped alongside mutability metadata.
    let value = details.get_document("value").unwrap();
    let version = value.get_str("version").unwrap();
    assert!(
        KNOWN_FCV_VERSIONS.contains(&version),
        "unexpected featureCompatibilityVersion.version: {version}"
    );
    assert!(!details.get_bool("settableAtRuntime").unwrap());
    assert!(!details.get_bool("settableAtStartup").unwrap());

    Ok(())
}

pub async fn validate_get_parameter_unknown(client: &Client) {
    let db = client.database("admin");
    commands::execute_command_and_validate_error(
        &db,
        doc! { "getParameter": 1, "someUnknownParameter": 1 },
        72,
        "no option found to get: someUnknownParameter",
        "InvalidOptions",
    )
    .await;
}

pub async fn validate_get_parameter_no_params(client: &Client) {
    let db = client.database("admin");
    commands::execute_command_and_validate_error(
        &db,
        doc! { "getParameter": 1 },
        9,
        "no parameters specified",
        "FailedToParse",
    )
    .await;
}

pub async fn validate_get_parameter_non_admin(client: &Client) {
    let db = client.database("get_parameter_non_admin");
    commands::execute_command_and_validate_error(
        &db,
        doc! { "getParameter": 1, "featureCompatibilityVersion": 1 },
        13,
        "admin database",
        "Unauthorized",
    )
    .await;
}
