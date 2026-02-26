/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/clients.rs
 *
 *-------------------------------------------------------------------------
 */

use mongodb::{
    error::Error,
    options::{AuthMechanism, ClientOptions, Credential, ServerAddress, Tls, TlsOptions},
    Client, Database,
};

pub const TEST_USERNAME: &str = "test";
pub const TEST_PASSWORD: &str = "test";

pub fn get_client() -> Client {
    let credential = Credential::builder()
        .username(TEST_USERNAME.to_string())
        .password(TEST_PASSWORD.to_string())
        .mechanism(AuthMechanism::ScramSha256)
        .build();

    let client_options = ClientOptions::builder()
        .credential(credential)
        .tls(Tls::Enabled(
            TlsOptions::builder()
                .allow_invalid_certificates(true)
                .build(),
        ))
        .hosts(vec![ServerAddress::parse("127.0.0.1:10260").unwrap()])
        .build();
    Client::with_options(client_options).unwrap()
}

pub fn get_client_insecure() -> Client {
    let credential = Credential::builder()
        .username(TEST_USERNAME.to_string())
        .password(TEST_PASSWORD.to_string())
        .mechanism(AuthMechanism::ScramSha256)
        .build();

    let client_options = ClientOptions::builder()
        .credential(credential)
        .hosts(vec![ServerAddress::parse("127.0.0.1:10260").unwrap()])
        .build();
    Client::with_options(client_options).unwrap()
}

pub fn get_client_unix_socket(path: &str) -> Client {
    use std::time::Duration;

    let credential = Credential::builder()
        .username(TEST_USERNAME.to_string())
        .password(TEST_PASSWORD.to_string())
        .mechanism(AuthMechanism::ScramSha256)
        .build();

    let client_options = ClientOptions::builder()
        .credential(credential)
        .hosts(vec![ServerAddress::parse(path).unwrap()])
        .connect_timeout(Duration::from_millis(100))
        .server_selection_timeout(Duration::from_millis(100))
        .build();
    Client::with_options(client_options).unwrap()
}

pub async fn setup_db(client: &Client, db: &str) -> Result<Database, Error> {
    let db = client.database(db);

    // Make sure the DB is clean
    db.drop().await?;
    Ok(db)
}
