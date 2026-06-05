/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/header.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::{
    error::{DocumentDBError, Result},
    protocol::{opcode::OpCode, MESSAGE_SIZE_EXCEEDED_ERROR},
};

/// Represents the message header (first 16 bytes of wire protocol message).
///
/// The header contains metadata about the message including its length, request/response IDs,
/// and the operation code that determines how to interpret the message body.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct Header {
    message_length: i32,
    request_id: i32,
    response_to: i32,
    op_code: OpCode,
}

impl Header {
    /// Size of the header in bytes (always 16 bytes)
    pub const LENGTH: usize = 16;
    pub const LENGTH_I32: i32 = 16;

    /// Creates a new header with the given fields.
    ///
    /// # Errors
    /// Returns an error if the length is negative, less than the header size, or exceeds
    /// the maximum message size.
    pub fn new(
        message_length: i32,
        request_id: i32,
        response_to: i32,
        op_code: OpCode,
    ) -> Result<Self> {
        let message_size = usize::try_from(message_length).map_err(|_err| {
            DocumentDBError::bad_value(
                "Message length could not be converted to a usize".to_owned(),
            )
        })?;

        if message_size < Self::LENGTH {
            return Err(DocumentDBError::bad_value(format!(
                "Message length must be at least {} bytes.",
                Self::LENGTH
            )));
        }

        if message_size > crate::protocol::MAX_MESSAGE_SIZE_BYTES as usize {
            return Err(DocumentDBError::bad_value(
                MESSAGE_SIZE_EXCEEDED_ERROR.to_owned(),
            ));
        }

        Ok(Self {
            message_length,
            request_id,
            response_to,
            op_code,
        })
    }

    /// Writes the header to the provided stream in wire format.
    ///
    /// Serializes all four header fields into a single 16-byte stack buffer
    /// and writes them in one bulk operation, reducing async overhead.
    ///
    /// # Arguments
    /// * `stream` - The stream to write to
    ///
    /// # Errors
    /// Returns an error if writing to the stream fails.
    pub async fn write_to<S>(&self, stream: &mut S) -> Result<()>
    where
        S: AsyncWrite + Unpin,
    {
        let mut buf = [0u8; Self::LENGTH];
        buf[0..4].copy_from_slice(&self.message_length.to_le_bytes());
        buf[4..8].copy_from_slice(&self.request_id.to_le_bytes());
        buf[8..12].copy_from_slice(&self.response_to.to_le_bytes());
        buf[12..16].copy_from_slice(&(self.op_code as i32).to_le_bytes());
        stream.write_all(&buf).await?;

        Ok(())
    }

    /// Reads a header from the provided stream.
    ///
    /// Reads exactly 16 bytes in a single bulk operation and parses
    /// the header fields synchronously, reducing async overhead.
    ///
    /// # Arguments
    /// * `reader` - The stream to read from
    ///
    /// # Returns
    /// The parsed header
    ///
    /// # Errors
    /// Returns an error if:
    /// - Reading from the stream fails
    /// - The stream contains insufficient data
    /// - The header is invalid (e.g., length is less than 16 bytes or message length exceeds the maximum allowed size)
    pub async fn read_from<S>(reader: &mut S) -> Result<Self>
    where
        S: AsyncRead + Unpin,
    {
        let mut buf = [0u8; Self::LENGTH];
        reader.read_exact(&mut buf).await?;

        let length = i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        let request_id = i32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let response_to = i32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]);
        let op_code = OpCode::from_value(i32::from_le_bytes([buf[12], buf[13], buf[14], buf[15]]));

        let header = Self::new(length, request_id, response_to, op_code)?;

        Ok(header)
    }

    /// Returns the length of the message in bytes, including the header.
    #[must_use]
    #[inline]
    pub const fn message_length(&self) -> i32 {
        self.message_length
    }

    /// Returns the ID of the request that this header corresponds to.
    #[must_use]
    #[inline]
    pub const fn request_id(&self) -> i32 {
        self.request_id
    }

    /// Returns the ID of the request that this header corresponds to.
    #[must_use]
    #[inline]
    pub const fn response_to(&self) -> i32 {
        self.response_to
    }

    /// Returns the operation code of the header.
    #[must_use]
    #[inline]
    pub const fn op_code(&self) -> OpCode {
        self.op_code
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn header_size_is_16_bytes() {
        assert_eq!(Header::LENGTH, 16);
        assert_eq!(Header::LENGTH_I32, 16);
        assert_eq!(std::mem::size_of::<Header>(), 16);
    }

    #[tokio::test]
    async fn write_produces_single_16_byte_buffer() {
        let header = Header {
            message_length: 100,
            request_id: 42,
            response_to: 0,
            op_code: OpCode::Msg,
        };

        let mut buf = Vec::new();
        header.write_to(&mut buf).await.unwrap();

        assert_eq!(buf.len(), 16);
        // Verify little-endian encoding
        assert_eq!(&buf[0..4], &100_i32.to_le_bytes());
        assert_eq!(&buf[4..8], &42_i32.to_le_bytes());
        assert_eq!(&buf[8..12], &0_i32.to_le_bytes());
        assert_eq!(&buf[12..16], &(OpCode::Msg as i32).to_le_bytes());
    }

    #[tokio::test]
    async fn read_from_parses_16_byte_buffer() {
        let mut raw = Vec::new();
        raw.extend_from_slice(&256_i32.to_le_bytes());
        raw.extend_from_slice(&7_i32.to_le_bytes());
        raw.extend_from_slice(&3_i32.to_le_bytes());
        raw.extend_from_slice(&2012_i32.to_le_bytes()); // Compressed

        let mut cursor = Cursor::new(raw);
        let header = Header::read_from(&mut cursor).await.unwrap();

        assert_eq!(header.message_length(), 256);
        assert_eq!(header.request_id(), 7);
        assert_eq!(header.response_to(), 3);
        assert_eq!(header.op_code(), OpCode::Compressed);
    }

    #[tokio::test]
    async fn round_trip_preserves_values() {
        let original = Header {
            message_length: 1024,
            request_id: -1,
            response_to: 12345,
            op_code: OpCode::Msg,
        };

        let mut buf = Vec::new();
        original.write_to(&mut buf).await.unwrap();

        let mut cursor = Cursor::new(buf);
        let restored = Header::read_from(&mut cursor).await.unwrap();

        assert_eq!(original.message_length(), restored.message_length());
        assert_eq!(original.request_id(), restored.request_id());
        assert_eq!(original.response_to(), restored.response_to());
        assert_eq!(original.op_code(), restored.op_code());
    }

    #[tokio::test]
    async fn read_from_insufficient_data_fails() {
        let mut cursor = Cursor::new(vec![0u8; 12]); // only 12 bytes, need 16
        let result = Header::read_from(&mut cursor).await;
        result.unwrap_err();
    }
}
