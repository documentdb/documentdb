/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/wire.rs
 *
 *-------------------------------------------------------------------------
 */

//! Owns gateway wire responses, response framing, and runtime error conversion.

use nacelle::{core::NacelleError, tcp::FrameBuffer};

use crate::{
    error::DocumentDBError,
    protocol::{header::Header, opcode::OpCode, OP_MSG_PREFIX_LENGTH, OP_REPLY_PREFIX_LENGTH},
    runtime::v2::protocol::gateway_max_frame_len,
};

/// Appends a response frame matching the request's wire opcode.
///
/// # Errors
///
/// Returns an error if the opcode is unsupported or the encoded frame exceeds its bound.
pub(super) fn append_wire_response(
    header: &Header,
    response: &[u8],
    dst: &mut FrameBuffer<'_>,
) -> std::result::Result<(), NacelleError> {
    match header.op_code() {
        OpCode::Msg => append_op_msg_response(header.request_id(), response, dst),
        #[expect(
            deprecated,
            reason = "OP_QUERY remains supported for legacy handshake clients"
        )]
        OpCode::Query => append_op_reply_response(header.request_id(), response, dst),
        #[expect(deprecated, reason = "OP_INSERT is a one-way legacy operation")]
        OpCode::Insert => Ok(()),
        op_code => Err(NacelleError::protocol(format!(
            "Unexpected response opcode: {op_code:?}"
        ))),
    }
}

/// Appends an `OP_MSG` response frame.
///
/// # Errors
///
/// Returns an error if the response length is invalid or the destination limit is exceeded.
pub(super) fn append_op_msg_response(
    request_id: i32,
    response: &[u8],
    dst: &mut FrameBuffer<'_>,
) -> std::result::Result<(), NacelleError> {
    let message_length = response_message_length(response.len(), OP_MSG_PREFIX_LENGTH)?;

    dst.extend_from_slice(&message_length.to_le_bytes())?;
    dst.extend_from_slice(&request_id.to_le_bytes())?;
    dst.extend_from_slice(&request_id.to_le_bytes())?;
    dst.extend_from_slice(&(OpCode::Msg as i32).to_le_bytes())?;
    dst.extend_from_slice(&0_u32.to_le_bytes())?;
    dst.extend_from_slice(&[0_u8])?;
    dst.extend_from_slice(response)?;

    Ok(())
}

#[expect(deprecated, reason = "OP_REPLY remains supported for legacy OP_QUERY")]
fn append_op_reply_response(
    request_id: i32,
    response: &[u8],
    dst: &mut FrameBuffer<'_>,
) -> std::result::Result<(), NacelleError> {
    let message_length = response_message_length(response.len(), OP_REPLY_PREFIX_LENGTH)?;

    dst.extend_from_slice(&message_length.to_le_bytes())?;
    dst.extend_from_slice(&request_id.to_le_bytes())?;
    dst.extend_from_slice(&request_id.to_le_bytes())?;
    dst.extend_from_slice(&(OpCode::Reply as i32).to_le_bytes())?;
    dst.extend_from_slice(&0_i32.to_le_bytes())?;
    dst.extend_from_slice(&0_i64.to_le_bytes())?;
    dst.extend_from_slice(&0_i32.to_le_bytes())?;
    dst.extend_from_slice(&1_i32.to_le_bytes())?;
    dst.extend_from_slice(response)?;

    Ok(())
}

/// Computes and validates a complete response frame length.
///
/// # Errors
///
/// Returns an error if the combined length overflows or exceeds the gateway wire limit.
pub(super) fn response_message_length(
    response_len: usize,
    framing_len: usize,
) -> std::result::Result<i32, NacelleError> {
    let max = gateway_max_frame_len();
    let total_len = response_len
        .checked_add(framing_len)
        .ok_or(NacelleError::FrameTooLarge {
            len: usize::MAX,
            max,
        })?;
    if total_len > max {
        return Err(NacelleError::FrameTooLarge {
            len: total_len,
            max,
        });
    }
    i32::try_from(total_len).map_err(NacelleError::protocol)
}

/// Converts a terminal runtime connection error to the gateway error type.
pub(super) fn error_to_documentdb(error: &NacelleError) -> DocumentDBError {
    DocumentDBError::internal_error(format!("Gateway runtime protocol failed: {error}."))
}

#[cfg(test)]
/// Returns the `OP_MSG` framing length for tests.
pub(super) const fn op_msg_prefix_length() -> usize {
    OP_MSG_PREFIX_LENGTH
}
