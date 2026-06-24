/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/reader.rs
 *
 * Stream I/O (read_header, read_request) and request dispatch
 * (parse_request). Per-opcode parsers live in sibling modules.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    io::{self, Cursor, ErrorKind},
    str::FromStr,
};

use bson::{RawDocument, RawDocumentBuf};
use bytes::BytesMut;
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    time::{timeout, Duration},
};

use crate::{
    error::{DocumentDBError, Result},
    protocol::{
        bson_scanner,
        header::Header,
        message::{self, Message, MessageSection},
        op_insert, op_query,
        opcode::OpCode,
    },
    requests::{
        extract_request_type_and_info_from_document, RequestExecutionMode, RequestMessage,
        RequestPreview, RequestType, StrictRequestInfo, WireRequest, WireRequestFrame,
    },
};

const fn is_connection_closed_error_kind(kind: ErrorKind) -> bool {
    matches!(
        kind,
        ErrorKind::UnexpectedEof
            | ErrorKind::BrokenPipe
            | ErrorKind::ConnectionReset
            | ErrorKind::ConnectionAborted
            | ErrorKind::NotConnected
            | ErrorKind::TimedOut
    )
}

pub(crate) fn is_connection_closed_error(error: &DocumentDBError) -> bool {
    error
        .as_io_error()
        .is_some_and(|io_error| is_connection_closed_error_kind(io_error.kind()))
}

pub(crate) fn is_idle_timeout_error(error: &DocumentDBError) -> bool {
    error
        .as_io_error()
        .is_some_and(|io_error| io_error.kind() == ErrorKind::TimedOut)
}

fn idle_timeout_error() -> DocumentDBError {
    io::Error::new(ErrorKind::TimedOut, "client socket idle timeout").into()
}

fn map_header_read_result(result: Result<Header>) -> Result<Option<Header>> {
    match result {
        Ok(header) => Ok(Some(header)),
        Err(error) => {
            if is_connection_closed_error(&error) {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}

/// Read a standard message header from the client stream with an idle timeout.
///
/// # Errors
///
/// Returns an error if the operation fails.
pub async fn read_header_with_timeout<S>(
    stream: &mut S,
    idle_timeout: Duration,
) -> Result<Option<Header>>
where
    S: AsyncRead + Unpin,
{
    match timeout(idle_timeout, Header::read_from(stream)).await {
        Ok(result) => map_header_read_result(result),
        Err(_) => Ok(None),
    }
}

fn request_message_size(authenticated: bool, header: &Header) -> Result<usize> {
    #[expect(
        clippy::cast_sign_loss,
        reason = "Header length is guaranteed to fit in usize"
    )]
    let message_size: usize = header.message_length() as usize - Header::LENGTH;

    if !authenticated && header.message_length() > crate::protocol::MAX_PRE_AUTH_MESSAGE_SIZE_BYTES
    {
        return Err(DocumentDBError::internal_error(
            "Message size exceeds the maximum allowed size.".to_owned(),
        ));
    }

    Ok(message_size)
}

fn request_message_from_body(header: &Header, message: BytesMut) -> RequestMessage {
    RequestMessage::new(
        message.freeze(),
        header.op_code(),
        header.request_id(),
        header.response_to(),
    )
}

/// Given an already read header, read the remaining message bytes into a
/// `RequestMessage` with an idle timeout.
///
/// # Errors
///
/// Returns an error if the operation fails or times out.
pub async fn read_request_with_timeout<S>(
    authenticated: bool,
    header: &Header,
    stream: &mut S,
    idle_timeout: Duration,
) -> Result<RequestMessage>
where
    S: AsyncRead + Unpin,
{
    let mut message = BytesMut::zeroed(request_message_size(authenticated, header)?);

    match timeout(idle_timeout, stream.read_exact(&mut message)).await {
        Ok(result) => result?,
        Err(_) => return Err(idle_timeout_error()),
    };

    Ok(request_message_from_body(header, message))
}

/// Parse a request message into a typed `WireRequest`.
///
/// Determines the request type from the first BSON element of the command document.
/// Common field extraction happens as part of parser output construction.
///
/// # Errors
/// Returns an error if the message has an unsupported opcode or cannot be parsed.
pub fn parse_request<'a>(
    message: &'a RequestMessage,
    requires_response: &mut bool,
) -> Result<WireRequest<'a>> {
    // Parse the specific message based on OpCode
    let request = match message.op_code() {
        OpCode::Msg => parse_msg(message, requires_response)?,
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => op_query::parse_query(message.request())?,
        #[expect(
            deprecated,
            reason = "OP_INSERT is still supported for legacy clients and testing"
        )]
        OpCode::Insert => op_insert::parse_insert(message)?,
        _ => Err(DocumentDBError::internal_error(format!(
            "Unimplemented: {:?}",
            message.op_code()
        )))?,
    };
    Ok(request.with_frame(WireRequestFrame::new(
        message.op_code(),
        message.request_id(),
        message.response_to(),
        *requires_response,
    )))
}

/// Parse only the command payload and identity from a request message.
///
/// This compatibility parser is used on parse-error paths to preserve request
/// identity for diagnostics when common metadata extraction fails.
///
/// # Errors
/// Returns an error if the message has an unsupported opcode or cannot be parsed.
pub fn parse_request_payload<'a>(
    message: &'a RequestMessage,
    requires_response: &mut bool,
) -> Result<RequestPreview<'a>> {
    let request = match message.op_code() {
        OpCode::Msg => parse_msg_payload(message, requires_response)?,
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => op_query::parse_query_payload(message.request())?,
        #[expect(
            deprecated,
            reason = "OP_INSERT is still supported for legacy clients and testing"
        )]
        OpCode::Insert => op_insert::parse_insert_payload(message)?,
        _ => Err(DocumentDBError::internal_error(format!(
            "Unimplemented: {:?}",
            message.op_code()
        )))?,
    };
    Ok(request.with_frame(WireRequestFrame::new(
        message.op_code(),
        message.request_id(),
        message.response_to(),
        *requires_response,
    )))
}

/// Read from a byte array until a nul terminator, parse using utf-8
///
/// # Errors
///
/// Returns an error if the operation fails.
pub fn str_from_u8_nul_utf8(utf8_src: &[u8]) -> Result<(&str, usize)> {
    let nul_range_end =
        utf8_src
            .iter()
            .position(|&c| c == b'\0')
            .ok_or(DocumentDBError::bad_value(
                "Message did not contain a string".to_owned(),
            ))?;

    let s = std::str::from_utf8(&utf8_src[0..nul_range_end]).map_err(|error| {
        tracing::error!("String was not a utf-8 string: {error}");
        DocumentDBError::bad_value("String was not a utf-8 string".to_owned())
    })?;

    Ok((s, nul_range_end))
}

/// Parse an `OP_MSG` — the primary command frame.
fn parse_msg<'a>(
    message: &'a RequestMessage,
    requires_response: &mut bool,
) -> Result<WireRequest<'a>> {
    let reader = Cursor::new(message.request_as_u8());
    let msg: Message = Message::read_from_op_msg(reader, message.response_to())?;

    *requires_response = !msg.flags.contains(message::MessageFlags::MORE_TO_COME);
    match msg.sections.len() {
        0 => Err(DocumentDBError::bad_value(
            "Message had no sections".to_owned(),
        )),
        1 => match &msg.sections[0] {
            MessageSection::Document(doc) => parse_cmd(doc, None),
            MessageSection::Sequence { .. } => Err(DocumentDBError::bad_value(
                "Expected the only section to be a document.".to_owned(),
            )),
        },
        2 => match (&msg.sections[0], &msg.sections[1]) {
            (MessageSection::Document(doc), MessageSection::Document(extra)) => {
                parse_cmd(doc, Some(extra.as_bytes()))
            }
            (
                MessageSection::Document(doc),
                MessageSection::Sequence {
                    documents: extras,
                    _identifier: identifier,
                    ..
                },
            ) => {
                let request = parse_cmd(doc, Some(extras))?;
                validate_sequence_identifier(request.request_type(), Some(identifier))?;
                Ok(request)
            }
            (MessageSection::Sequence { .. }, _) => Err(DocumentDBError::bad_value(
                "Expected first section to be a single document.".to_owned(),
            )),
        },
        _ => Err(DocumentDBError::bad_value(
            "Expected at most two sections.".to_owned(),
        )),
    }
}

fn parse_msg_payload<'a>(
    message: &'a RequestMessage,
    requires_response: &mut bool,
) -> Result<RequestPreview<'a>> {
    let reader = Cursor::new(message.request_as_u8());
    let msg: Message = Message::read_from_op_msg(reader, message.response_to())?;

    *requires_response = !msg.flags.contains(message::MessageFlags::MORE_TO_COME);
    match msg.sections.len() {
        0 => Err(DocumentDBError::bad_value(
            "Message had no sections".to_owned(),
        )),
        1 => match &msg.sections[0] {
            MessageSection::Document(doc) => parse_cmd_payload(doc, None),
            MessageSection::Sequence { .. } => Err(DocumentDBError::bad_value(
                "Expected the only section to be a document.".to_owned(),
            )),
        },
        2 => match (&msg.sections[0], &msg.sections[1]) {
            (MessageSection::Document(doc), MessageSection::Document(extra)) => {
                parse_cmd_payload(doc, Some(extra.as_bytes()))
            }
            (
                MessageSection::Document(doc),
                MessageSection::Sequence {
                    documents: extras,
                    _identifier: identifier,
                    ..
                },
            ) => {
                let request = parse_cmd_payload(doc, Some(extras))?;
                validate_sequence_identifier(request.request_type(), Some(identifier))?;
                Ok(request)
            }
            (MessageSection::Sequence { .. }, _) => Err(DocumentDBError::bad_value(
                "Expected first section to be a single document.".to_owned(),
            )),
        },
        _ => Err(DocumentDBError::bad_value(
            "Expected at most two sections.".to_owned(),
        )),
    }
}

fn validate_sequence_identifier(
    request_type: RequestType,
    sequence_identifier: Option<&str>,
) -> Result<()> {
    let Some(identifier) = sequence_identifier else {
        return Ok(());
    };

    let expected = match request_type {
        RequestType::Insert => Some("documents"),
        RequestType::Update => Some("updates"),
        RequestType::Delete => Some("deletes"),
        _ => None,
    };

    if expected.is_some_and(|expected| expected != identifier) {
        return Err(DocumentDBError::bad_value(format!(
            "Unexpected document sequence identifier '{identifier}' for {request_type}"
        )));
    }

    Ok(())
}

/// Parse a command document - shared by `OP_QUERY` and `OP_MSG` paths.
///
/// Uses a single BSON scanner pass to extract the command identity and common metadata.
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub fn parse_cmd<'a>(command: &'a RawDocument, extra: Option<&'a [u8]>) -> Result<WireRequest<'a>> {
    let (request_type, common) = extract_request_type_and_info_from_document(command)?;
    let common = StrictRequestInfo::try_from_info(common)?;
    let execution = execution_for(request_type, command, &common);

    let request = WireRequest::from_borrowed_parts(
        request_type,
        execution.mode,
        None,
        command,
        extra,
        common,
    );

    Ok(match execution.explain_target {
        Some(target) => request.with_borrowed_explain_target(target.document, target.collection),
        None => request,
    })
}

/// Parse a command document into a payload-only request.
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub fn parse_cmd_payload<'a>(
    command: &'a RawDocument,
    extra: Option<&'a [u8]>,
) -> Result<RequestPreview<'a>> {
    let request_type = request_type_from_command(command)?;
    let db_hint = command.get_str("$db").ok();

    Ok(RequestPreview::from_borrowed_parts(
        request_type,
        None,
        command,
        extra,
        db_hint,
    ))
}

/// Parse a command document into a payload-only request with known database metadata.
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub(crate) fn parse_cmd_payload_with_db<'a>(
    command: &'a RawDocument,
    extra: Option<&'a [u8]>,
    db: &'a str,
) -> Result<RequestPreview<'a>> {
    let request_type = request_type_from_command(command)?;
    Ok(RequestPreview::from_borrowed_parts(
        request_type,
        None,
        command,
        extra,
        Some(db),
    ))
}

/// Parse an owned command document into a `WireRequest`.
///
/// This is used by legacy opcode adapters that construct a normalized command document before
/// handing it to the unified request boundary.
///
/// # Errors
/// Returns an error if the command document is empty, contains an unrecognized command, or has
/// invalid common metadata.
pub(crate) fn parse_cmd_buf(command: RawDocumentBuf) -> Result<WireRequest<'static>> {
    let (request_type, common) = extract_request_type_and_info_from_document(command.as_ref())?;
    let common = StrictRequestInfo::try_from_info(common)?;
    let (execution_mode, target_collection) = {
        let execution = execution_for(request_type, command.as_ref(), &common);
        (
            execution.mode,
            execution
                .explain_target
                .and_then(|target| target.collection.map(str::to_owned)),
        )
    };
    let common = common.into_owned_metadata();

    let request =
        WireRequest::from_owned_command(request_type, execution_mode, None, command, None, common)
            .with_owned_explain_target_collection(target_collection);

    Ok(request)
}

/// Parse an owned command document into a payload-only `WireRequest`.
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub(crate) fn parse_cmd_buf_payload(command: RawDocumentBuf) -> Result<RequestPreview<'static>> {
    let request_type = request_type_from_command(command.as_ref())?;
    let db_hint = command.as_ref().get_str("$db").ok().map(str::to_owned);

    Ok(RequestPreview::from_owned_command(
        request_type,
        None,
        command,
        None,
        db_hint,
    ))
}

fn request_type_from_command(command: &RawDocument) -> Result<RequestType> {
    let (cmd_name, _element_type) = bson_scanner::first_field_name(command.as_bytes())?;
    RequestType::from_str(cmd_name)
}

#[derive(Clone, Copy, Debug)]
struct ParsedExecution<'a> {
    mode: RequestExecutionMode,
    explain_target: Option<ParsedExplainTarget<'a>>,
}

#[derive(Clone, Copy, Debug)]
struct ParsedExplainTarget<'a> {
    document: &'a RawDocument,
    collection: Option<&'a str>,
}

fn execution_for<'a>(
    request_type: RequestType,
    command: &'a RawDocument,
    common: &StrictRequestInfo<'_>,
) -> ParsedExecution<'a> {
    if request_type != RequestType::Explain && common.is_explain() {
        return ParsedExecution {
            mode: RequestExecutionMode::InlineExplain,
            explain_target: None,
        };
    }

    if request_type == RequestType::Explain {
        if let Some((target_type, target)) = explain_target_metadata(command) {
            return ParsedExecution {
                mode: RequestExecutionMode::ExplainWrapper { target_type },
                explain_target: Some(target),
            };
        }
    }

    ParsedExecution {
        mode: RequestExecutionMode::Normal,
        explain_target: None,
    }
}

fn explain_target_metadata(
    command: &RawDocument,
) -> Option<(RequestType, ParsedExplainTarget<'_>)> {
    let target = command.get_document("explain").ok()?;
    let (name, first_field) = target.into_iter().next()?.ok()?;
    let target_type = RequestType::from_str(name).ok()?;

    Some((
        target_type,
        ParsedExplainTarget {
            document: target,
            collection: first_field.as_str(),
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    use bson::{doc, rawdoc, Document};
    use bytes::Bytes;

    use crate::testing::{
        build_document_section, build_document_sequence_section, build_op_msg_parts_with_sections,
        build_raw_document,
    };

    /// Builds an `OP_MSG` wire-format `RequestMessage` from a BSON command document.
    fn make_op_msg(doc: &bson::RawDocumentBuf) -> RequestMessage {
        let mut buf = Vec::new();
        // flags = 0 (no MORE_TO_COME, no CHECKSUM)
        buf.extend_from_slice(&0_u32.to_le_bytes());
        // payload type 0 = single document
        buf.push(0);
        // the BSON document
        buf.extend_from_slice(doc.as_bytes());

        RequestMessage::new(Bytes::from(buf), OpCode::Msg, 1, 0)
    }

    fn make_op_msg_from_body(body: Vec<u8>, request_id: i32) -> RequestMessage {
        RequestMessage::new(Bytes::from(body), OpCode::Msg, request_id, 0)
    }

    fn raw_documents_bytes(documents: &[Document]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for document in documents {
            bytes.extend_from_slice(build_raw_document(document).as_bytes());
        }
        bytes
    }

    #[test]
    fn parse_request_find_command() {
        let doc = rawdoc! { "find": "mycoll", "$db": "testdb" };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert_eq!(request.request_type(), RequestType::Find);
        let frame = request
            .frame()
            .expect("parser should attach frame metadata");
        assert_eq!(frame.op_code(), OpCode::Msg);
        assert_eq!(frame.request_id(), 1);
        assert_eq!(frame.response_to(), 0);
        assert!(frame.requires_response());
        assert!(requires_response);
    }

    #[test]
    fn parse_request_aggregate_command() {
        let doc = rawdoc! { "aggregate": "mycoll", "$db": "testdb" };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert_eq!(request.request_type(), RequestType::Aggregate);
    }

    #[test]
    fn parse_request_accepts_document_sequence_before_command_document() {
        let command = doc! { "insert": "users", "$db": "myapp" };
        let documents = vec![doc! { "_id": 1_i32 }, doc! { "_id": 2_i32 }];
        let sequence_section = build_document_sequence_section("documents", &documents);
        let command_section = build_document_section(&command);
        let (header, body) =
            build_op_msg_parts_with_sections(&[sequence_section, command_section], 2);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();

        assert_eq!(request.request_type(), RequestType::Insert);
        assert_eq!(request.extra().unwrap(), raw_documents_bytes(&documents));
        assert!(requires_response);
    }

    #[test]
    fn parse_request_accepts_update_document_sequence_identifier() {
        let command = doc! { "update": "users", "$db": "myapp" };
        let updates = vec![doc! { "q": { "_id": 1_i32 }, "u": { "$set": { "a": 2_i32 } } }];
        let sequence_section = build_document_sequence_section("updates", &updates);
        let command_section = build_document_section(&command);
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, sequence_section], 8);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();

        assert_eq!(request.request_type(), RequestType::Update);
        assert_eq!(request.extra().unwrap(), raw_documents_bytes(&updates));
    }

    #[test]
    fn parse_request_accepts_delete_document_sequence_identifier() {
        let command = doc! { "delete": "users", "$db": "myapp" };
        let deletes = vec![doc! { "q": { "_id": 1_i32 }, "limit": 1_i32 }];
        let sequence_section = build_document_sequence_section("deletes", &deletes);
        let command_section = build_document_section(&command);
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, sequence_section], 9);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();

        assert_eq!(request.request_type(), RequestType::Delete);
        assert_eq!(request.extra().unwrap(), raw_documents_bytes(&deletes));
    }

    #[test]
    fn parse_request_rejects_wrong_document_sequence_identifier() {
        let command = doc! { "insert": "users", "$db": "myapp" };
        let documents = vec![doc! { "_id": 1_i32 }];
        let sequence_section = build_document_sequence_section("updates", &documents);
        let command_section = build_document_section(&command);
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, sequence_section], 10);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request(&msg, &mut requires_response)
            .expect_err("insert must reject non-documents sequence identifier");
    }

    #[test]
    fn parse_request_payload_rejects_wrong_document_sequence_identifier() {
        let command = doc! { "delete": "users", "$db": "myapp" };
        let deletes = vec![doc! { "q": { "_id": 1_i32 }, "limit": 1_i32 }];
        let sequence_section = build_document_sequence_section("documents", &deletes);
        let command_section = build_document_section(&command);
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, sequence_section], 11);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request_payload(&msg, &mut requires_response)
            .expect_err("delete must reject non-deletes sequence identifier");
    }

    #[test]
    fn parse_request_preserves_document_extra_section() {
        let command = doc! { "find": "users", "$db": "myapp" };
        let extra = doc! { "cursor": { "batchSize": 10_i32 } };
        let command_section = build_document_section(&command);
        let extra_section = build_document_section(&extra);
        let (header, body) = build_op_msg_parts_with_sections(&[command_section, extra_section], 3);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();

        assert_eq!(request.request_type(), RequestType::Find);
        assert_eq!(
            request.extra().unwrap(),
            build_raw_document(&extra).as_bytes()
        );
    }

    #[test]
    fn parse_request_rejects_sequence_without_command_document() {
        let documents = vec![doc! { "_id": 1_i32 }];
        let sequence_section = build_document_sequence_section("documents", &documents);
        let (header, body) = build_op_msg_parts_with_sections(&[sequence_section], 4);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request(&msg, &mut requires_response).unwrap_err();
    }

    #[test]
    fn parse_request_rejects_unsupported_section_payload_type() {
        let command = doc! { "insert": "users", "$db": "myapp" };
        let command_section = build_document_section(&command);
        let unsupported_section = vec![2, 0, 0, 0, 0];
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, unsupported_section], 5);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request(&msg, &mut requires_response).unwrap_err();
    }

    #[test]
    fn parse_request_rejects_truncated_document_sequence() {
        let command = doc! { "insert": "users", "$db": "myapp" };
        let command_section = build_document_section(&command);
        let mut truncated_sequence = Vec::new();
        truncated_sequence.push(1);
        truncated_sequence.extend_from_slice(&32_i32.to_le_bytes());
        truncated_sequence.extend_from_slice(b"documents\0");
        let (header, body) =
            build_op_msg_parts_with_sections(&[command_section, truncated_sequence], 6);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request(&msg, &mut requires_response).unwrap_err();
    }

    #[test]
    fn parse_request_rejects_sequence_identifier_past_declared_section() {
        let command = doc! { "insert": "users", "$db": "myapp" };
        let command_section = build_document_section(&command);
        let mut sequence = Vec::new();
        sequence.push(1);
        sequence.extend_from_slice(&7_i32.to_le_bytes());
        sequence.extend_from_slice(b"abc\0");
        let (header, body) = build_op_msg_parts_with_sections(&[command_section, sequence], 7);
        let msg = make_op_msg_from_body(body, header.request_id());
        let mut requires_response = true;

        parse_request(&msg, &mut requires_response).unwrap_err();
    }

    #[test]
    fn parse_request_explain_as_command_name() {
        // Top-level explain command: { explain: { find: "coll" }, ... }
        let doc = rawdoc! {
            "explain": { "find": "mycoll" },
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert_eq!(request.request_type(), RequestType::Explain);
    }

    #[test]
    fn parse_request_explain_wrapper_caches_target_collection() {
        let doc = rawdoc! {
            "explain": { "find": "mycoll" },
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        let target = request.explain_target().unwrap();

        assert_eq!(target.request_type(), RequestType::Find);
        assert_eq!(target.collection(), Some("mycoll"));
    }

    #[test]
    fn parse_request_explain_wrapper_preserves_non_string_target_collection() {
        let doc = rawdoc! {
            "explain": { "aggregate": 1_i32 },
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        let target = request.explain_target().unwrap();

        assert_eq!(target.request_type(), RequestType::Aggregate);
        assert_eq!(target.collection(), None);
    }

    #[test]
    fn parse_request_explain_boolean_is_not_inline_explain() {
        let doc = rawdoc! {
            "explain": true,
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();

        assert_eq!(request.request_type(), RequestType::Explain);
        assert_eq!(request.execution_mode(), RequestExecutionMode::Normal);
        let error = request
            .explain_target()
            .expect_err("top-level explain with non-document target should fail");
        assert!(
            error
                .to_string()
                .contains("Explain command was not a document"),
            "unexpected error: {error:?}"
        );
    }

    #[test]
    fn extract_common_detects_explain_flag() {
        // explain: true as a sub-field on a find command
        let doc = rawdoc! {
            "find": "mycoll",
            "explain": true,
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        // parse_request returns Find (first element determines type)
        assert_eq!(request.request_type(), RequestType::Find);

        // The parser extracts common metadata with the request.
        assert!(request.is_explain());
        // execution_request_type routes the command to explain processing without
        // changing the parsed request identity.
        assert_eq!(request.execution_request_type(), RequestType::Explain);
    }

    #[test]
    fn extract_common_no_explain_flag() {
        let doc = rawdoc! {
            "find": "mycoll",
            "$db": "testdb",
            "maxTimeMS": 5000
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert!(!request.is_explain());
        assert_eq!(request.execution_request_type(), RequestType::Find);
        assert_eq!(request.db(), "testdb");
    }

    #[test]
    fn extract_common_explain_false_not_override() {
        let doc = rawdoc! {
            "aggregate": "mycoll",
            "explain": false,
            "$db": "testdb"
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert!(!request.is_explain());
        assert_eq!(request.execution_request_type(), RequestType::Aggregate);
    }

    #[test]
    #[expect(deprecated, reason = "testing legacy OP_INSERT path")]
    fn parse_request_op_insert_does_not_panic() {
        // Construct minimal OP_INSERT message
        let collection = b"testdb.mycoll\0";
        let flags: i32 = 0;
        let doc = rawdoc! { "_id": 1, "value": "test" };

        let mut request_bytes = Vec::new();
        request_bytes.extend_from_slice(&flags.to_le_bytes());
        request_bytes.extend_from_slice(collection);
        request_bytes.extend_from_slice(doc.as_bytes());

        let msg = RequestMessage::new(Bytes::from(request_bytes), OpCode::Insert, 1, 0);
        let mut requires_response = true;

        // This must NOT panic (previously hit unreachable!())
        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert_eq!(request.request_type(), RequestType::Insert);
        let frame = request
            .frame()
            .expect("parser should attach frame metadata");
        assert_eq!(frame.op_code(), OpCode::Insert);
    }

    #[test]
    fn extract_common_extracts_all_fields() {
        let doc = rawdoc! {
            "find": "users",
            "$db": "myapp",
            "maxTimeMS": 3000,
            "readConcern": { "level": "majority" }
        };
        let msg = make_op_msg(&doc);
        let mut requires_response = true;

        let request = parse_request(&msg, &mut requires_response).unwrap();
        assert_eq!(request.db(), "myapp");
        assert_eq!(request.max_time_ms(), Some(3000));
        assert!(!request.is_explain());
    }

    #[test]
    fn parse_cmd_empty_document_returns_error() {
        let doc = rawdoc! {};
        parse_cmd(&doc, None).unwrap_err();
    }

    #[test]
    fn parse_cmd_unknown_command_returns_error() {
        let doc = rawdoc! { "unknownCommand": 1 };
        parse_cmd(&doc, None).unwrap_err();
    }

    #[test]
    fn parse_cmd_payload_keeps_database_when_other_common_fields_are_invalid() {
        let doc = rawdoc! {
            "find": "users",
            "$db": "myapp",
            "maxTimeMS": "not a number",
        };

        parse_cmd(&doc, None).expect_err("strict parsing should reject invalid maxTimeMS");
        let request =
            parse_cmd_payload(&doc, None).expect("payload parsing should preserve identity");

        assert_eq!(request.db_hint(), Some("myapp"));
    }
}

#[cfg(test)]
mod timeout_tests {
    use std::{
        io,
        pin::Pin,
        task::{Context, Poll},
    };

    use tokio::{
        io::{AsyncRead, ReadBuf},
        time::Duration,
    };

    use crate::protocol::reader::read_header_with_timeout;

    const NON_EXPIRING_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

    struct ErrorReader {
        kind: io::ErrorKind,
    }

    impl AsyncRead for ErrorReader {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Poll::Ready(Err(io::Error::from(self.kind)))
        }
    }

    struct PendingReader;

    impl AsyncRead for PendingReader {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Poll::Pending
        }
    }

    #[tokio::test]
    async fn read_header_treats_closed_connection_errors_as_eof() {
        for kind in [
            io::ErrorKind::UnexpectedEof,
            io::ErrorKind::BrokenPipe,
            io::ErrorKind::ConnectionReset,
            io::ErrorKind::ConnectionAborted,
            io::ErrorKind::NotConnected,
            io::ErrorKind::TimedOut,
        ] {
            let mut reader = ErrorReader { kind };

            assert!(
                read_header_with_timeout(&mut reader, NON_EXPIRING_IDLE_TIMEOUT)
                    .await
                    .expect("closed connection errors should not be surfaced")
                    .is_none(),
                "{kind:?} should be treated as connection closure"
            );
        }
    }

    #[tokio::test]
    async fn read_header_with_timeout_returns_none_when_idle() {
        let mut reader = PendingReader;

        assert!(
            read_header_with_timeout(&mut reader, Duration::ZERO)
                .await
                .expect("idle header timeout should not be surfaced")
                .is_none(),
            "idle header timeout should close the connection"
        );
    }

    #[tokio::test]
    async fn read_header_preserves_non_connection_errors() {
        let mut reader = ErrorReader {
            kind: io::ErrorKind::PermissionDenied,
        };

        let error = read_header_with_timeout(&mut reader, NON_EXPIRING_IDLE_TIMEOUT)
            .await
            .expect_err("non-connection errors should be surfaced");

        assert_eq!(
            error
                .as_io_error()
                .expect("error should preserve its io source")
                .kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
