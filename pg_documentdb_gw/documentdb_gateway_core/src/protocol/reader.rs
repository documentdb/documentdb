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
    io::{Cursor, ErrorKind},
    str::FromStr,
};

use bson::RawDocument;
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::{
    error::{DocumentDBError, ErrorKind as DocumentDBErrorKind, Result},
    protocol::{
        header::Header,
        message::{self, Message, MessageSection},
        op_insert, op_query,
        opcode::OpCode,
    },
    requests::{Request, RequestMessage, RequestType},
};

/// Read a standard message header from the client stream
///
/// # Errors
///
/// Returns an error if the operation fails.
pub async fn read_header<S>(stream: &mut S) -> Result<Option<Header>>
where
    S: AsyncRead + Unpin,
{
    match Header::read_from(stream).await {
        Ok(header) => Ok(Some(header)),
        Err(error) => {
            let is_disconnect = matches!(
                error.kind(),
                DocumentDBErrorKind::IoError(io_error, _)
                    if matches!(
                        io_error.kind(),
                        ErrorKind::UnexpectedEof
                            | ErrorKind::BrokenPipe
                            | ErrorKind::ConnectionReset
                    )
            );

            if is_disconnect {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}

/// Given an already read header, read the remaining message bytes into a `RequestMessage`
///
/// # Errors
///
/// Returns an error if the operation fails.
pub async fn read_request<S>(header: &Header, stream: &mut S) -> Result<RequestMessage>
where
    S: AsyncRead + Unpin,
{
    let message_size = usize::try_from(header.length).map_err(|error| {
        tracing::error!("Message length could not be converted to a usize: {error}");
        DocumentDBError::bad_value("Message length could not be converted to a usize".to_owned())
    })?;

    // 16 bytes of the message were already used by the headers
    let mut message: Vec<u8> = vec![0; message_size - Header::LENGTH];

    stream.read_exact(&mut message).await?;

    Ok(RequestMessage {
        request: message,
        op_code: header.op_code,
        request_id: header.request_id,
        response_to: header.response_to,
    })
}

/// Parse a request message into a typed Request
///
/// # Errors
/// Returns an error if the message has an unsupported opcode or cannot be parsed.
pub fn parse_request<'a>(
    message: &'a RequestMessage,
    requires_response: &mut bool,
) -> Result<Request<'a>> {
    // Parse the specific message based on OpCode
    let request = match message.op_code {
        OpCode::Msg => parse_msg(message, requires_response)?,
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => op_query::parse_query(&message.request)?,
        #[expect(
            deprecated,
            reason = "OP_INSERT is still supported for legacy clients and testing"
        )]
        OpCode::Insert => op_insert::parse_insert(message)?,
        _ => Err(DocumentDBError::internal_error(format!(
            "Unimplemented: {:?}",
            message.op_code
        )))?,
    };
    Ok(request)
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
    let s = ::std::str::from_utf8(&utf8_src[0..nul_range_end]).map_err(|error| {
        tracing::error!("String was not a utf-8 string: {error}");
        DocumentDBError::bad_value("String was not a utf-8 string".to_owned())
    })?;
    Ok((s, nul_range_end))
}

/// Parse an `OP_MSG`
fn parse_msg<'a>(message: &'a RequestMessage, requires_response: &mut bool) -> Result<Request<'a>> {
    let reader = Cursor::new(message.request.as_slice());
    let msg: Message = Message::read_from_op_msg(reader, message.response_to)?;

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
                    documents: extras, ..
                },
            ) => parse_cmd(doc, Some(extras)),
            (MessageSection::Sequence { .. }, _) => Err(DocumentDBError::bad_value(
                "Expected first section to be a single document.".to_owned(),
            )),
        },
        _ => Err(DocumentDBError::bad_value(
            "Expected at most two sections.".to_owned(),
        )),
    }
}

/// Parse a command document - shared by `OP_QUERY` and `OP_MSG` paths.
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub fn parse_cmd<'a>(command: &'a RawDocument, extra: Option<&'a [u8]>) -> Result<Request<'a>> {
    if let Some(result) = command.into_iter().next() {
        let cmd_name = result?.0;

        // TODO: This operation is expensive and should consider dropping or using alternative approaches if it becomes a bottleneck.
        let explain = command.get_bool("explain").unwrap_or(false);
        if explain {
            return Ok(Request::Raw(RequestType::Explain, command, extra));
        }

        let request_type = RequestType::from_str(cmd_name)?;
        Ok(Request::Raw(request_type, command, extra))
    } else {
        Err(DocumentDBError::bad_value(
            "Admin command received without a command.".to_owned(),
        ))
    }
}
