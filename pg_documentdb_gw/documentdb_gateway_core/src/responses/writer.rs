/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/writer.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, Result},
    protocol::{
        header::Header, opcode::OpCode, MAX_MESSAGE_SIZE_BYTES, MESSAGE_SIZE_EXCEEDED_ERROR,
    },
    responses::{CommandError, Response},
};
use bson::RawDocument;
use tokio::io::{AsyncWrite, AsyncWriteExt};

const OP_MSG_PREFIX_LENGTH: usize =
    Header::LENGTH + std::mem::size_of::<u32>() + std::mem::size_of::<u8>();
const OP_REPLY_PREFIX_LENGTH: usize = Header::LENGTH + 20;

fn message_size_exceeded_error() -> DocumentDBError {
    DocumentDBError::internal_error(MESSAGE_SIZE_EXCEEDED_ERROR.to_owned())
}

fn response_message_length(response_len: usize, overhead_len: usize) -> Result<i32> {
    let total_length = response_len
        .checked_add(overhead_len)
        .ok_or_else(message_size_exceeded_error)?;

    let message_length =
        i32::try_from(total_length).map_err(|_err| message_size_exceeded_error())?;

    if message_length > MAX_MESSAGE_SIZE_BYTES {
        return Err(message_size_exceeded_error());
    }

    Ok(message_length)
}

fn pack_header(
    buf: &mut [u8],
    message_length: i32,
    request_id: i32,
    response_to: i32,
    op_code: OpCode,
) {
    buf[0..4].copy_from_slice(&message_length.to_le_bytes());
    buf[4..8].copy_from_slice(&request_id.to_le_bytes());
    buf[8..12].copy_from_slice(&response_to.to_le_bytes());
    buf[12..16].copy_from_slice(&(op_code as i32).to_le_bytes());
}

/// Write a server response to the client stream
/// # Errors
/// Returns error if the operation fails.
pub async fn write<S>(header: &Header, response: &Response, stream: &mut S) -> Result<()>
where
    S: AsyncWrite + Unpin,
{
    write_and_flush(header, response.as_raw_document()?, stream).await
}

/// Write a raw BSON object to the client stream
/// # Errors
/// Returns error if the operation fails.
pub async fn write_and_flush<S>(
    header: &Header,
    response: &RawDocument,
    stream: &mut S,
) -> Result<()>
where
    S: AsyncWrite + Unpin,
{
    // The format of the response will depend on the OP which the client sent
    match header.op_code() {
        OpCode::Command => unimplemented!(),

        // Messages are always responded to with messages
        OpCode::Msg => write_message(header, response, stream).await,

        // Query is responded to with Reply
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => {
            let message_length =
                response_message_length(response.as_bytes().len(), OP_REPLY_PREFIX_LENGTH)?;

            let mut buf = [0u8; OP_REPLY_PREFIX_LENGTH];
            pack_header(
                &mut buf,
                message_length,
                header.request_id(),
                header.request_id(),
                OpCode::Reply,
            );
            buf[32..36].copy_from_slice(&1_i32.to_le_bytes());

            stream.write_all(&buf).await?;
            stream.write_all(response.as_bytes()).await?;
            Ok(())
        }

        // Insert has no response
        #[expect(
            deprecated,
            reason = "OP_INSERT is still supported for legacy clients and testing"
        )]
        OpCode::Insert => Ok(()),
        _ => Err(DocumentDBError::internal_error(format!(
            "Unexpected response opcode: {:?}",
            header.op_code()
        ))),
    }?;

    stream.flush().await?;

    Ok(())
}

/// Serializes the Message to bytes and writes them to `writer`.
/// # Errors
/// Returns error if the operation fails.
pub async fn write_message<S>(header: &Header, response: &RawDocument, writer: &mut S) -> Result<()>
where
    S: AsyncWrite + Unpin,
{
    write_message_for_request_id(header.request_id(), response, writer).await
}

async fn write_message_for_request_id<S>(
    request_id: i32,
    response: &RawDocument,
    writer: &mut S,
) -> Result<()>
where
    S: AsyncWrite + Unpin,
{
    let message_length = response_message_length(response.as_bytes().len(), OP_MSG_PREFIX_LENGTH)?;

    let mut buf = [0u8; OP_MSG_PREFIX_LENGTH];
    pack_header(
        &mut buf,
        message_length,
        request_id,
        request_id,
        OpCode::Msg,
    );

    writer.write_all(&buf).await?;
    writer.write_all(response.as_bytes()).await?;

    Ok(())
}

/// # Errors
/// Returns error if the operation fails.
pub async fn write_error_without_header<S>(
    connection_context: &ConnectionContext,
    err: DocumentDBError,
    stream: &mut S,
    activity_id: &str,
) -> Result<()>
where
    S: AsyncWrite + Unpin,
{
    let response =
        CommandError::from_error(connection_context, &err, activity_id).to_raw_document_buf();

    write_message_for_request_id(0, &response, stream).await?;
    stream.flush().await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_message_length_rejects_oversized_message() {
        let response_len = usize::try_from(MAX_MESSAGE_SIZE_BYTES)
            .expect("maximum message size should fit into usize");

        response_message_length(response_len, 1).unwrap_err();
    }

    #[test]
    fn pack_header_writes_wire_fields() {
        let mut buf = [0u8; OP_MSG_PREFIX_LENGTH];

        pack_header(&mut buf, 42, 7, 11, OpCode::Msg);

        assert_eq!(&buf[0..4], &42_i32.to_le_bytes());
        assert_eq!(&buf[4..8], &7_i32.to_le_bytes());
        assert_eq!(&buf[8..12], &11_i32.to_le_bytes());
        assert_eq!(&buf[12..16], &(OpCode::Msg as i32).to_le_bytes());
    }
}
