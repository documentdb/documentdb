/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/request.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{RawDocument, RawDocumentBuf};

use crate::{
    error::Result,
    requests::{common_fields, info::RequestInfo, request_type::RequestType},
};

#[derive(Debug)]
pub enum Request {
    RawBuf(RequestType, RawDocumentBuf),
}

impl Request {
    #[must_use]
    pub(crate) const fn request_type(&self) -> RequestType {
        match self {
            Self::RawBuf(t, _) => *t,
        }
    }

    #[must_use]
    pub(crate) fn document(&self) -> &RawDocument {
        match self {
            Self::RawBuf(_, d) => d,
        }
    }

    #[must_use]
    pub(crate) const fn extra(&self) -> Option<&[u8]> {
        match self {
            Self::RawBuf(_, _) => None,
        }
    }

    /// # Errors
    /// Returns error if common field extraction fails.
    pub(crate) fn extract_common(&self) -> Result<RequestInfo<'_>> {
        common_fields::extract_info_from_document(self.document(), self.request_type())
    }
}
