/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/mod.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{rawdoc, Document, RawDocument};

use crate::error::Result;
use crate::protocol::OK_SUCCEEDED;

pub mod constant;
mod error;
mod pg;
mod raw;
pub mod writer;

pub use error::CommandError;
pub use pg::PgResponse;
pub use raw::RawResponse;

#[derive(Debug)]
pub enum Response {
    Raw(RawResponse),
    Pg(PgResponse),
}

impl Response {
    pub fn as_raw_document(&self) -> Result<&RawDocument> {
        match self {
            Response::Pg(pg) => pg.as_raw_document(),
            Response::Raw(raw) => raw.as_raw_document(),
        }
    }

    /// Returns the byte length of the response BSON document, or 0 if unavailable.
    pub fn response_byte_len(&self) -> usize {
        match self {
            Response::Pg(pg) => pg.response_byte_len(),
            Response::Raw(raw) => raw.response_byte_len(),
        }
    }

    pub fn as_json(&self) -> Result<Document> {
        Ok(Document::try_from(self.as_raw_document()?)?)
    }

    pub fn ok() -> Self {
        Response::Raw(RawResponse(rawdoc! {
            "ok":OK_SUCCEEDED,
        }))
    }
}

#[cfg(test)]
mod tests {
    use bson::rawdoc;

    use crate::responses::{raw::RawResponse, Response};

    #[test]
    fn raw_response_byte_len_matches_bson_bytes() {
        // An empty BSON document is exactly 5 bytes: 4-byte i32 size + 1 null terminator.
        let empty = rawdoc! {};
        assert_eq!(Response::Raw(RawResponse(empty)).response_byte_len(), 5);

        // { "ok": 1.0 } = 4 (size) + [1 (type 0x01 double) + 3 ("ok\0") + 8 (f64)] + 1 (null) = 17
        let ok_response = Response::ok();
        assert_eq!(ok_response.response_byte_len(), 17);

        // Verify against an independent code path: serialize to bson::Document and
        // re-encode, so we aren't comparing as_bytes().len() against itself.
        let doc = rawdoc! { "value": "test" };
        let roundtripped: bson::Document =
            bson::from_slice(doc.as_bytes()).expect("valid BSON should deserialize");
        let mut re_encoded = Vec::new();
        roundtripped
            .to_writer(&mut re_encoded)
            .expect("re-encoding should succeed");
        assert_eq!(
            Response::Raw(RawResponse(doc)).response_byte_len(),
            re_encoded.len()
        );
    }
}
