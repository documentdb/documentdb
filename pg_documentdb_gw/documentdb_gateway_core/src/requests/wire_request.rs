/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/wire_request.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{borrow::Cow, str::FromStr};

use bson::{Document, RawBsonRef, RawDocument, RawDocumentBuf};
use bytes::Bytes;

#[cfg(test)]
use crate::requests::info::RequestInfo;
use crate::{
    context::{LogicalSessionId, RequestTransactionInfo},
    error::{DocumentDBError, Result},
    protocol::{bson_scanner, opcode::OpCode},
    requests::{
        common_fields::extract_info_from_document, info::StrictRequestInfo,
        read_concern::ReadConcern, request_type::RequestType,
    },
};

/// Request execution routing metadata derived from a parsed wire request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequestExecutionMode {
    /// Execute the parsed command normally.
    Normal,
    /// Route the parsed command through explain processing without changing
    /// the parsed command identity.
    InlineExplain,
    /// Route a top-level explain wrapper to explain processing for the target command.
    ExplainWrapper { target_type: RequestType },
}

impl RequestExecutionMode {
    /// Returns the command type that should be used for dispatcher routing.
    ///
    /// This is separate from parsed request identity. Callers that make telemetry, redaction, or
    /// authorization decisions should use `WireRequest::request_type` instead.
    #[must_use]
    pub const fn request_type(self, parsed_type: RequestType) -> RequestType {
        match self {
            Self::Normal => parsed_type,
            Self::InlineExplain | Self::ExplainWrapper { .. } => RequestType::Explain,
        }
    }
}

/// The command document that should be explained.
#[derive(Clone, Copy, Debug)]
pub struct ExplainTarget<'a> {
    request_type: RequestType,
    document: &'a RawDocument,
    collection: Option<&'a str>,
}

impl<'a> ExplainTarget<'a> {
    #[must_use]
    pub const fn new(request_type: RequestType, document: &'a RawDocument) -> Self {
        Self {
            request_type,
            document,
            collection: None,
        }
    }

    #[must_use]
    pub const fn with_collection(
        request_type: RequestType,
        document: &'a RawDocument,
        collection: &'a str,
    ) -> Self {
        Self {
            request_type,
            document,
            collection: Some(collection),
        }
    }

    #[must_use]
    pub const fn request_type(&self) -> RequestType {
        self.request_type
    }

    #[must_use]
    pub const fn document(&self) -> &'a RawDocument {
        self.document
    }

    #[must_use]
    pub const fn collection(&self) -> Option<&'a str> {
        self.collection
    }
}

/// Immutable metadata from the frame that carried a request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WireRequestFrame {
    op_code: OpCode,
    request_id: i32,
    response_to: i32,
    requires_response: bool,
}

impl WireRequestFrame {
    /// Creates frame metadata for a parsed request.
    #[must_use]
    pub const fn new(
        op_code: OpCode,
        request_id: i32,
        response_to: i32,
        requires_response: bool,
    ) -> Self {
        Self {
            op_code,
            request_id,
            response_to,
            requires_response,
        }
    }

    /// Returns the operation code from the request frame.
    #[must_use]
    pub const fn op_code(&self) -> OpCode {
        self.op_code
    }

    /// Returns the wire protocol request identifier.
    #[must_use]
    pub const fn request_id(&self) -> i32 {
        self.request_id
    }

    /// Returns the request identifier this frame responds to.
    #[must_use]
    pub const fn response_to(&self) -> i32 {
        self.response_to
    }

    /// Returns whether this request expects a response frame.
    #[must_use]
    pub const fn requires_response(&self) -> bool {
        self.requires_response
    }
}

#[derive(Debug)]
enum WireRequestBodyStorage<'a> {
    Borrowed {
        command: &'a RawDocument,
        extra: Option<&'a [u8]>,
    },
    OwnedCommand {
        command: RawDocumentBuf,
        extra: Option<Bytes>,
    },
}

/// Byte storage for the command document and any bulk payload bytes.
#[derive(Debug)]
struct WireRequestBody<'a> {
    storage: WireRequestBodyStorage<'a>,
}

impl<'a> WireRequestBody<'a> {
    /// Creates body storage from command bytes borrowed from an existing request value.
    #[must_use]
    const fn borrowed(command: &'a RawDocument, extra: Option<&'a [u8]>) -> Self {
        Self {
            storage: WireRequestBodyStorage::Borrowed { command, extra },
        }
    }
}

impl WireRequestBody<'static> {
    /// Creates body storage from an owned command document and optional bulk payload bytes.
    #[must_use]
    const fn owned_command(command: RawDocumentBuf, extra: Option<Bytes>) -> Self {
        Self {
            storage: WireRequestBodyStorage::OwnedCommand { command, extra },
        }
    }
}

impl WireRequestBody<'_> {
    /// Returns the command document represented by this body.
    #[must_use]
    pub fn command(&self) -> &RawDocument {
        match &self.storage {
            WireRequestBodyStorage::Borrowed { command, .. } => command,
            WireRequestBodyStorage::OwnedCommand { command, .. } => command,
        }
    }

    /// Returns any bulk payload bytes associated with this request body.
    #[must_use]
    pub fn extra(&self) -> Option<&[u8]> {
        match &self.storage {
            WireRequestBodyStorage::Borrowed { extra, .. } => *extra,
            WireRequestBodyStorage::OwnedCommand { extra, .. } => extra.as_deref(),
        }
    }
}

/// A lenient request preview used for parse-error telemetry.
#[derive(Debug)]
pub struct RequestPreview<'a> {
    request_type: RequestType,
    frame: Option<WireRequestFrame>,
    body: WireRequestBody<'a>,
    db_hint: Option<Cow<'a, str>>,
}

impl<'a> RequestPreview<'a> {
    #[must_use]
    pub(crate) fn from_borrowed_parts(
        request_type: RequestType,
        frame: Option<WireRequestFrame>,
        command: &'a RawDocument,
        extra: Option<&'a [u8]>,
        db_hint: Option<&'a str>,
    ) -> Self {
        Self {
            request_type,
            frame,
            body: WireRequestBody::borrowed(command, extra),
            db_hint: db_hint.map(Cow::Borrowed),
        }
    }

    #[must_use]
    pub(crate) const fn with_frame(mut self, frame: WireRequestFrame) -> Self {
        self.frame = Some(frame);
        self
    }

    /// Returns the parsed command identity.
    #[must_use]
    pub const fn request_type(&self) -> RequestType {
        self.request_type
    }

    /// Returns the database hint recovered from the command body or legacy namespace.
    #[must_use]
    pub fn db_hint(&self) -> Option<&str> {
        self.db_hint.as_deref()
    }

    /// Returns frame metadata when the preview was built from a wire frame.
    #[must_use]
    pub const fn frame(&self) -> Option<&WireRequestFrame> {
        self.frame.as_ref()
    }

    /// Returns the command document for telemetry and diagnostics.
    #[must_use]
    pub fn document(&self) -> &RawDocument {
        self.body.command()
    }

    /// Returns any bulk payload bytes associated with this request preview.
    #[must_use]
    pub fn extra(&self) -> Option<&[u8]> {
        self.body.extra()
    }
}

impl RequestPreview<'static> {
    #[must_use]
    pub(crate) fn from_owned_command(
        request_type: RequestType,
        frame: Option<WireRequestFrame>,
        command: RawDocumentBuf,
        extra: Option<Bytes>,
        db_hint: Option<String>,
    ) -> Self {
        Self {
            request_type,
            frame,
            body: WireRequestBody::owned_command(command, extra),
            db_hint: db_hint.map(Cow::Owned),
        }
    }
}

/// Request metadata observed by telemetry and metrics.
#[derive(Clone, Copy, Debug)]
pub enum RequestObservation<'request, 'data> {
    /// A fully parsed executable request.
    Strict(&'request WireRequest<'data>),
    /// A best-effort parse preview for error paths.
    Preview(&'request RequestPreview<'data>),
}

impl<'request> RequestObservation<'request, '_> {
    /// Returns the parsed command identity.
    #[must_use]
    pub const fn request_type(self) -> RequestType {
        match self {
            Self::Strict(request) => request.request_type(),
            Self::Preview(preview) => preview.request_type(),
        }
    }

    /// Returns the database name for strict requests, or a best-effort database hint for previews.
    #[must_use]
    pub fn db(self) -> Option<&'request str> {
        match self {
            Self::Strict(request) => Some(request.db()),
            Self::Preview(preview) => preview.db_hint(),
        }
    }

    /// Returns the command document for telemetry and diagnostics.
    #[must_use]
    pub fn document(self) -> &'request RawDocument {
        match self {
            Self::Strict(request) => request.document(),
            Self::Preview(preview) => preview.document(),
        }
    }
}

/// A parsed request value produced by the wire-protocol parser.
#[derive(Debug)]
pub struct WireRequest<'a> {
    request_type: RequestType,
    execution_mode: RequestExecutionMode,
    frame: Option<WireRequestFrame>,
    body: WireRequestBody<'a>,
    common: StrictRequestInfo<'a>,
    explain_target_document: Option<&'a RawDocument>,
    explain_target_collection: Option<Cow<'a, str>>,
}

impl<'a> WireRequest<'a> {
    #[must_use]
    const fn from_parts(
        request_type: RequestType,
        execution_mode: RequestExecutionMode,
        frame: Option<WireRequestFrame>,
        body: WireRequestBody<'a>,
        common: StrictRequestInfo<'a>,
    ) -> Self {
        Self {
            request_type,
            execution_mode,
            frame,
            body,
            common,
            explain_target_document: None,
            explain_target_collection: None,
        }
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn from_request_and_info(
        request: &'a crate::requests::Request,
        common: RequestInfo<'a>,
    ) -> Self {
        let common = StrictRequestInfo::try_from_info(common).unwrap_or_else(|error| {
            panic!("test request should have strict metadata: {error:?}");
        });
        let execution_mode = if common.is_explain() {
            RequestExecutionMode::InlineExplain
        } else {
            RequestExecutionMode::Normal
        };
        Self::from_parts(
            request.request_type(),
            execution_mode,
            None,
            WireRequestBody::borrowed(request.document(), request.extra()),
            common,
        )
    }

    /// Creates a request from borrowed command bytes and extracted metadata.
    #[must_use]
    pub(crate) const fn from_borrowed_parts(
        request_type: RequestType,
        execution_mode: RequestExecutionMode,
        frame: Option<WireRequestFrame>,
        command: &'a RawDocument,
        extra: Option<&'a [u8]>,
        common: StrictRequestInfo<'a>,
    ) -> Self {
        Self::from_parts(
            request_type,
            execution_mode,
            frame,
            WireRequestBody::borrowed(command, extra),
            common,
        )
    }
}

impl WireRequest<'static> {
    /// Creates an owned request from body storage and metadata that may borrow temporary input.
    #[must_use]
    fn from_owned_parts(
        request_type: RequestType,
        execution_mode: RequestExecutionMode,
        frame: Option<WireRequestFrame>,
        body: WireRequestBody<'static>,
        common: StrictRequestInfo<'_>,
    ) -> Self {
        Self {
            request_type,
            execution_mode,
            frame,
            body,
            common: common.into_owned_metadata(),
            explain_target_document: None,
            explain_target_collection: None,
        }
    }

    /// Creates an owned request from an owned command document and optional bulk payload bytes.
    #[must_use]
    pub(crate) fn from_owned_command(
        request_type: RequestType,
        execution_mode: RequestExecutionMode,
        frame: Option<WireRequestFrame>,
        command: RawDocumentBuf,
        extra: Option<Bytes>,
        common: StrictRequestInfo<'_>,
    ) -> Self {
        Self::from_owned_parts(
            request_type,
            execution_mode,
            frame,
            WireRequestBody::owned_command(command, extra),
            common,
        )
    }

    /// Creates an owned request from an owned command document, extracting common metadata.
    ///
    /// # Errors
    ///
    /// Returns an error if recognized common metadata has an invalid type.
    pub fn from_owned_command_document(
        request_type: RequestType,
        execution_mode: RequestExecutionMode,
        frame: Option<WireRequestFrame>,
        command: RawDocumentBuf,
        extra: Option<Bytes>,
    ) -> Result<Self> {
        let (command_name, _) = bson_scanner::first_field_name(command.as_bytes())?;
        let command_request_type = RequestType::from_str(command_name)?;
        if command_request_type != request_type {
            return Err(DocumentDBError::bad_value(format!(
                "Owned command document starts with '{command_name}' but request type is {request_type}"
            )));
        }

        let common = {
            let common = extract_info_from_document(&command, request_type)?;
            StrictRequestInfo::try_from_info(common)?.into_owned_metadata()
        };
        Ok(Self::from_owned_command(
            request_type,
            execution_mode,
            frame,
            command,
            extra,
            common,
        ))
    }
}

impl<'a> WireRequest<'a> {
    #[must_use]
    pub(crate) const fn with_frame(mut self, frame: WireRequestFrame) -> Self {
        self.frame = Some(frame);
        self
    }

    #[must_use]
    pub(crate) fn with_borrowed_explain_target(
        mut self,
        document: &'a RawDocument,
        collection: Option<&'a str>,
    ) -> Self {
        self.explain_target_document = Some(document);
        self.explain_target_collection = collection.map(Cow::Borrowed);
        self
    }

    #[must_use]
    pub(crate) fn with_owned_explain_target_collection(
        mut self,
        collection: Option<String>,
    ) -> Self {
        self.explain_target_collection = collection.map(Cow::Owned);
        self
    }

    /// Returns the parsed command identity for security, telemetry, and redaction decisions.
    #[must_use]
    pub const fn request_type(&self) -> RequestType {
        self.request_type
    }

    /// Returns routing metadata that describes how this request should execute.
    #[must_use]
    pub const fn execution_mode(&self) -> RequestExecutionMode {
        self.execution_mode
    }

    /// Returns the command type that should be used for dispatcher routing.
    ///
    /// This is separate from parsed request identity. Callers that make telemetry, redaction, or
    /// authorization decisions should use `WireRequest::request_type` instead.
    #[must_use]
    pub const fn execution_request_type(&self) -> RequestType {
        self.execution_mode.request_type(self.request_type)
    }

    /// Returns the document and command identity that explain processing should target.
    ///
    /// # Errors
    ///
    /// Returns an error if a top-level explain wrapper does not contain a document target.
    pub fn explain_target(&'a self) -> Result<ExplainTarget<'a>> {
        match self.execution_mode {
            RequestExecutionMode::InlineExplain => {
                Ok(ExplainTarget::new(self.request_type, self.document()))
            }
            RequestExecutionMode::ExplainWrapper { target_type } => {
                let target = if let Some(target) = self.explain_target_document {
                    target
                } else {
                    self.document()
                        .get_document("explain")
                        .map_err(DocumentDBError::parse_failure())?
                };
                Ok(
                    if let Some(collection) = self.explain_target_collection.as_deref() {
                        ExplainTarget::with_collection(target_type, target, collection)
                    } else {
                        ExplainTarget::new(target_type, target)
                    },
                )
            }
            RequestExecutionMode::Normal if self.request_type == RequestType::Explain => Err(
                DocumentDBError::bad_value("Explain command was not a document.".to_owned()),
            ),
            RequestExecutionMode::Normal => Err(DocumentDBError::bad_value(
                "Request is not an explain request.".to_owned(),
            )),
        }
    }

    /// Returns frame metadata when the request was built from a wire frame.
    #[must_use]
    pub const fn frame(&self) -> Option<&WireRequestFrame> {
        self.frame.as_ref()
    }

    /// Returns the command document for this request.
    #[must_use]
    pub fn document(&self) -> &RawDocument {
        self.body.command()
    }

    /// Returns any bulk payload bytes associated with this request.
    #[must_use]
    pub fn extra(&self) -> Option<&[u8]> {
        self.body.extra()
    }

    /// Converts the command document to an owned BSON document.
    ///
    /// # Errors
    ///
    /// Returns an error if the command document cannot be converted.
    pub fn to_json(&self) -> Result<Document> {
        Ok(Document::try_from(self.document())?)
    }

    /// Iterates over raw fields in the command document.
    ///
    /// # Errors
    ///
    /// Returns an error if raw field iteration fails or the callback returns an error.
    pub fn extract_fields<F>(&self, mut f: F) -> Result<()>
    where
        F: FnMut(&str, RawBsonRef) -> Result<()>,
    {
        for entry in self.document() {
            let (key, value) = entry?;
            f(key, value)?;
        }
        Ok(())
    }

    /// Returns the database name from strict request metadata.
    #[must_use]
    pub fn db(&self) -> &str {
        self.common.db()
    }

    /// Returns the collection name from common request metadata.
    ///
    /// # Errors
    ///
    /// Returns an error if the command does not have collection metadata.
    pub fn collection(&self) -> Result<&str> {
        self.common.collection()
    }

    /// Returns the `maxTimeMS` value from common request metadata.
    #[must_use]
    pub const fn max_time_ms(&self) -> Option<i64> {
        self.common.max_time_ms()
    }

    /// Returns transaction metadata extracted from the command document.
    #[must_use]
    pub const fn transaction_info(&self) -> Option<&RequestTransactionInfo> {
        self.common.transaction_info()
    }

    /// Returns the logical session identifier extracted from the command document.
    #[must_use]
    pub const fn lsid(&self) -> Option<&LogicalSessionId> {
        self.common.lsid()
    }

    /// Returns read concern metadata extracted from the command document.
    #[must_use]
    pub const fn read_concern(&self) -> &ReadConcern {
        self.common.read_concern()
    }

    /// Returns whether the parsed command requested inline explain handling.
    #[must_use]
    pub const fn is_explain(&self) -> bool {
        self.common.is_explain()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use bson::rawdoc;

    #[test]
    fn wire_request_keeps_identity_separate_from_execution_mode() {
        let wire_request = WireRequest::from_owned_command_document(
            RequestType::Find,
            RequestExecutionMode::InlineExplain,
            None,
            rawdoc! {
                "find": "users",
                "explain": true,
                "$db": "app",
            },
            None,
        )
        .expect("common fields should parse");

        assert_eq!(wire_request.request_type(), RequestType::Find);
        assert_eq!(
            wire_request.execution_mode(),
            RequestExecutionMode::InlineExplain
        );
        assert_eq!(wire_request.execution_request_type(), RequestType::Explain);
        assert_eq!(wire_request.db(), "app");
        assert!(wire_request.is_explain());
    }

    #[test]
    fn wire_request_exposes_get_more_collection_metadata() {
        let wire_request = WireRequest::from_owned_command_document(
            RequestType::GetMore,
            RequestExecutionMode::Normal,
            None,
            rawdoc! {
                "getMore": 42_i64,
                "collection": "users",
                "$db": "app",
            },
            None,
        )
        .expect("common fields should parse");

        assert_eq!(wire_request.request_type(), RequestType::GetMore);
        assert_eq!(
            wire_request
                .collection()
                .expect("collection should be present"),
            "users"
        );
    }

    #[test]
    fn owned_command_document_rejects_mismatched_request_type() {
        WireRequest::from_owned_command_document(
            RequestType::Aggregate,
            RequestExecutionMode::Normal,
            None,
            rawdoc! {
                "$db": "app",
                "aggregate": "users",
            },
            None,
        )
        .expect_err("owned command construction should enforce command-first request identity");
    }
}
