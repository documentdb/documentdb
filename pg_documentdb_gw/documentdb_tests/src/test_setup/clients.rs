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

fn test_credentials(user: &str, password: &str) -> Credential {
    Credential::builder()
        .username(user.to_owned())
        .password(password.to_owned())
        .mechanism(AuthMechanism::ScramSha256)
        .build()
}

/// Creates a `MongoDB` test client with TLS but no authentication.
/// Used for pre-auth commands like `hello` and `isMaster`.
///
/// # Errors
///
/// Returns an error if the server address cannot be parsed or the client
/// cannot be constructed with the given options.
pub fn get_client_unauthenticated() -> std::result::Result<Client, Error> {
    let client_options = ClientOptions::builder()
        .tls(Tls::Enabled(
            TlsOptions::builder()
                .allow_invalid_certificates(true)
                .build(),
        ))
        .hosts(vec![ServerAddress::parse("127.0.0.1:10260")?])
        .build();

    Client::with_options(client_options)
}

/// Creates a `MongoDB` test client with TLS and SCRAM-SHA-256 authentication.
///
/// # Errors
///
/// Returns an error if the server address cannot be parsed or the client
/// cannot be constructed with the given options.
pub fn get_client() -> std::result::Result<Client, Error> {
    let credential = test_credentials(TEST_USERNAME, TEST_PASSWORD);

    let client_options = ClientOptions::builder()
        .credential(credential)
        .tls(Tls::Enabled(
            TlsOptions::builder()
                .allow_invalid_certificates(true)
                .build(),
        ))
        .hosts(vec![ServerAddress::parse("127.0.0.1:10260")?])
        .build();

    Client::with_options(client_options)
}

/// Creates a `MongoDB` test client without TLS.
///
/// # Errors
///
/// Returns an error if the server address cannot be parsed or the client
/// cannot be constructed with the given options.
pub fn get_client_insecure() -> std::result::Result<Client, Error> {
    let credential = test_credentials(TEST_USERNAME, TEST_PASSWORD);

    let client_options = ClientOptions::builder()
        .credential(credential)
        .hosts(vec![ServerAddress::parse("127.0.0.1:10260")?])
        .build();
    Client::with_options(client_options)
}

/// Creates a `MongoDB` test client that connects via a Unix domain socket.
///
/// # Errors
///
/// Returns an error if the socket address cannot be parsed or the client
/// cannot be constructed with the given options.
pub fn get_client_unix_socket(path: &str) -> std::result::Result<Client, Error> {
    use std::time::Duration;

    let credential = test_credentials(TEST_USERNAME, TEST_PASSWORD);

    let client_options = ClientOptions::builder()
        .credential(credential)
        .hosts(vec![ServerAddress::parse(path)?])
        .connect_timeout(Duration::from_millis(100))
        .server_selection_timeout(Duration::from_millis(100))
        .build();

    Client::with_options(client_options)
}

/// Drops and returns a fresh database handle for the given name.
///
/// # Errors
///
/// Returns an error if the database cannot be dropped.
pub async fn setup_db(client: &Client, db: &str) -> Result<Database, Error> {
    let db = client.database(db);

    // Make sure the DB is clean
    db.drop().await?;
    Ok(db)
}
