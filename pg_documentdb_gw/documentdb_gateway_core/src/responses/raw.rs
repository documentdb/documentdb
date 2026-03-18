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
pub struct RawResponse(pub RawDocumentBuf);

impl RawResponse {
    /// Returns the raw document
    #[must_use]
    pub fn as_raw_document(&self) -> &RawDocument {
        &self.0
    }

    /// Returns the byte length of the raw BSON document.
    #[must_use]
    pub fn response_byte_len(&self) -> usize {
        self.0.as_bytes().len()
    }
}
