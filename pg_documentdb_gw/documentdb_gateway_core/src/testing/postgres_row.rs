/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 *-------------------------------------------------------------------------
 */

//! Constructs decoded `PostgreSQL` rows without a database server.

#![expect(
    clippy::unwrap_used,
    reason = "Opt-in protocol fixtures fail fast on invalid test data"
)]

use std::collections::HashMap;

use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio_postgres::{types::Type, NoTls, Row};

/// Decodes a single binary column through the `PostgreSQL` client.
///
/// # Panics
/// Panics if the in-memory protocol exchange fails.
pub async fn test_postgres_row(column_type: Type, value: Vec<u8>) -> Row {
    let (client_stream, mut server) = tokio::io::duplex(64 * 1024);
    let server_task = tokio::spawn(async move {
        let startup_length = server.read_u32().await.unwrap();
        let mut startup = vec![0; usize::try_from(startup_length - 4).unwrap()];
        server.read_exact(&mut startup).await.unwrap();
        send(&mut server, b'R', &0_i32.to_be_bytes()).await;
        send(&mut server, b'Z', b"I").await;
        let mut statements = HashMap::new();
        let mut typeinfo = false;
        while let Ok(tag) = server.read_u8().await {
            let length = server.read_u32().await.unwrap();
            let mut body = vec![0; usize::try_from(length - 4).unwrap()];
            server.read_exact(&mut body).await.unwrap();
            match tag {
                b'P' => {
                    let mut fields = body.split(|byte| *byte == 0);
                    let name = fields.next().unwrap().to_vec();
                    let sql = fields.next().unwrap();
                    statements.insert(name, sql.starts_with(b"SELECT t.typname"));
                    send(&mut server, b'1', &[]).await;
                }
                b'B' => {
                    let name = body.split(|byte| *byte == 0).nth(1).unwrap();
                    typeinfo = statements[name];
                    send(&mut server, b'2', &[]).await;
                }
                b'D' => {
                    let name = body[1..].split(|byte| *byte == 0).next().unwrap();
                    let describe_typeinfo = statements[name];
                    let mut parameters = Vec::new();
                    parameters.extend(i16::from(describe_typeinfo).to_be_bytes());
                    if describe_typeinfo {
                        parameters.extend(Type::OID.oid().to_be_bytes());
                    }
                    send(&mut server, b't', &parameters).await;
                    let types = if describe_typeinfo {
                        vec![
                            Type::TEXT,
                            Type::CHAR,
                            Type::OID,
                            Type::OID,
                            Type::OID,
                            Type::TEXT,
                            Type::OID,
                        ]
                    } else {
                        vec![column_type.clone()]
                    };
                    let description = describe_columns(&types);
                    send(&mut server, b'T', &description).await;
                }
                b'E' => {
                    let mut row = Vec::new();
                    let values = if typeinfo {
                        vec![
                            Some(column_type.name().as_bytes().to_vec()),
                            Some(vec![b'b']),
                            Some(0_u32.to_be_bytes().to_vec()),
                            None,
                            Some(0_u32.to_be_bytes().to_vec()),
                            Some(b"public".to_vec()),
                            Some(0_u32.to_be_bytes().to_vec()),
                        ]
                    } else {
                        vec![Some(value.clone())]
                    };
                    row.extend(i16::try_from(values.len()).unwrap().to_be_bytes());
                    for value in values {
                        if let Some(value) = value {
                            row.extend(i32::try_from(value.len()).unwrap().to_be_bytes());
                            row.extend(value);
                        } else {
                            row.extend((-1_i32).to_be_bytes());
                        }
                    }
                    send(&mut server, b'D', &row).await;
                    send(&mut server, b'C', b"SELECT 1\0").await;
                }
                b'S' => send(&mut server, b'Z', b"I").await,
                b'X' => break,
                _ => panic!("unexpected protocol message"),
            }
        }
    });
    let (client, connection) = tokio_postgres::Config::new()
        .user("test")
        .connect_raw(client_stream, NoTls)
        .await
        .unwrap();
    let driver = tokio::spawn(connection);
    let row = client.query("SELECT value", &[]).await.unwrap().remove(0);
    drop(client);
    driver.await.unwrap().unwrap();
    server_task.await.unwrap();
    row
}

fn describe_columns(types: &[Type]) -> Vec<u8> {
    let mut description = Vec::new();
    description.extend(i16::try_from(types.len()).unwrap().to_be_bytes());
    for ty in types {
        description.extend(b"value\0");
        description.extend(0_u32.to_be_bytes());
        description.extend(0_i16.to_be_bytes());
        description.extend(ty.oid().to_be_bytes());
        description.extend((-1_i16).to_be_bytes());
        description.extend((-1_i32).to_be_bytes());
        description.extend(0_i16.to_be_bytes());
    }
    description
}

async fn send(server: &mut DuplexStream, tag: u8, body: &[u8]) {
    server.write_u8(tag).await.unwrap();
    server
        .write_u32(u32::try_from(body.len() + 4).unwrap())
        .await
        .unwrap();
    server.write_all(body).await.unwrap();
}
