/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/raw.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{RawDocument, RawDocumentBuf};

/// Response constructed by the gateway from a raw BSON document.
#[derive(Debug)]
pub struct RawResponse {
    document: RawDocumentBuf,
    has_write_errors: bool,
}

impl RawResponse {
    /// Creates a new `RawResponse` from a raw BSON document.
    #[must_use]
    pub const fn new(document: RawDocumentBuf) -> Self {
        Self {
            document,
            has_write_errors: false,
        }
    }

    /// Marks this response as containing write errors.
    #[must_use]
    pub const fn with_write_errors(mut self) -> Self {
        self.has_write_errors = true;
        self
    }

    /// Returns `true` if the response contains write errors that were
    /// transformed from the `PostgreSQL` UDF result.
    #[must_use]
    pub const fn has_write_errors(&self) -> bool {
        self.has_write_errors
    }

    /// Returns the raw document
    #[must_use]
    pub fn as_raw_document(&self) -> &RawDocument {
        &self.document
    }

    /// Returns the byte length of the raw BSON document.
    #[must_use]
    pub fn response_byte_len(&self) -> usize {
        self.document.as_bytes().len()
    }
}
