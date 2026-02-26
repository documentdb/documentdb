/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/unauthenticated_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::constant, test_setup::initialize};
use mongodb::{
    error::Error,
    options::{ClientOptions, ServerAddress, Tls, TlsOptions},
    Client,
};

#[tokio::test]
async fn is_master() -> Result<(), Error> {
    let _ = initialize::initialize().await;

    let client = Client::with_options(
        ClientOptions::builder()
            .hosts(vec![ServerAddress::parse("127.0.0.1:10260").unwrap()])
            .tls(Tls::Enabled(
                TlsOptions::builder()
                    .allow_invalid_certificates(true)
                    .build(),
            ))
            .build(),
    )
    .unwrap();

    constant::validate_is_master_unauthenticated(&client).await
}
