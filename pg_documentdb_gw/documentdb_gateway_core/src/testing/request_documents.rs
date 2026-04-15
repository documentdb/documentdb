/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/request_documents.rs
 *
 * Shared BSON request fixtures for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, spec::BinarySubtype, Binary, Document};

pub fn logout_document() -> Document {
    doc! {
        "logout": 1_i32,
        "$db": "admin",
    }
}

pub fn ping_document() -> Document {
    doc! {
        "ping": 1_i32,
        "$db": "admin",
    }
}

pub fn invalid_transaction_find_document() -> Document {
    doc! {
        "find": "system.profile",
        "$db": "test",
        "lsid": {
            "id": Binary {
                subtype: BinarySubtype::Generic,
                bytes: vec![1, 2, 3, 4],
            }
        },
        "txnNumber": 1_i64,
        "autocommit": false,
        "startTransaction": true,
    }
}

pub fn malformed_sasl_start_document() -> Document {
    doc! {
        "saslStart": 1_i32,
        "$db": "admin",
    }
}
