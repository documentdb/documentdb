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
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    time::{timeout, Duration},
};

use crate::{
    error::{DocumentDBError, Result},
    protocol::{
        header::Header,
        message::{self, Message, MessageSection},
        op_insert, op_query,
        opcode::OpCode,
        MESSAGE_SIZE_EXCEEDED_ERROR,
    },
    requests::{Request, RequestMessage, RequestType},
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
            MESSAGE_SIZE_EXCEEDED_ERROR.to_owned(),
        ));
    }

    Ok(message_size)
}

const fn request_message_from_body(header: &Header, message: Vec<u8>) -> RequestMessage {
    RequestMessage {
        request: message,
        op_code: header.op_code(),
        request_id: header.request_id(),
        response_to: header.response_to(),
    }
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
    let mut message = vec![0; request_message_size(authenticated, header)?];

    match timeout(idle_timeout, stream.read_exact(&mut message)).await {
        Ok(result) => result?,
        Err(_) => return Err(idle_timeout_error()),
    };

    Ok(request_message_from_body(header, message))
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

/// Parse a command from an owned `RawDocumentBuf` — used when the gateway
/// has constructed a synthetic document (e.g., injecting `$db` for `OP_QUERY`).
///
/// # Errors
/// Returns an error if the command document is empty or contains an unrecognized command.
pub fn parse_cmd_buf(command: RawDocumentBuf) -> Result<Request<'static>> {
    if let Some(result) = command.iter().next() {
        let cmd_name = result?.0;

        let explain = command.get_bool("explain").unwrap_or(false);
        if explain {
            return Ok(Request::RawBuf(RequestType::Explain, command));
        }

        let request_type = RequestType::from_str(cmd_name)?;

        Ok(Request::RawBuf(request_type, command))
    } else {
        Err(DocumentDBError::bad_value(
            "Admin command received without a command.".to_owned(),
        ))
    }
}

#[cfg(test)]
mod tests {
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
