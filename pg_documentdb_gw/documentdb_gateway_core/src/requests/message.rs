/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/message.rs
 *
 *-------------------------------------------------------------------------
 */

use bytes::Bytes;

use crate::protocol::opcode::OpCode;

/// The `RequestMessage` holds ownership to the whole client message.
///
/// Other objects, like the `Request` will only hold references to it.
#[derive(Debug)]
pub struct RequestMessage {
    request: Bytes,
    op_code: OpCode,
    request_id: i32,
    response_to: i32,
}

impl RequestMessage {
    pub const fn new(request: Bytes, op_code: OpCode, request_id: i32, response_to: i32) -> Self {
        Self {
            request,
            op_code,
            request_id,
            response_to,
        }
    }

    #[must_use]
    pub const fn request(&self) -> &Bytes {
        &self.request
    }

    pub fn request_as_u8(&self) -> &[u8] {
        &self.request
    }

    #[must_use]
    pub const fn op_code(&self) -> OpCode {
        self.op_code
    }

    #[must_use]
    pub const fn request_id(&self) -> i32 {
        self.request_id
    }

    #[must_use]
    pub const fn response_to(&self) -> i32 {
        self.response_to
    }
}
