/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/read_ahead.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    future::{poll_fn, Future},
    pin::Pin,
    task::Poll,
};

use tokio::io::AsyncRead;

use crate::{
    error::Result,
    protocol::{self, header::Header},
};

pub(super) type PendingHeaderRead<'a> =
    Pin<Box<dyn Future<Output = Result<Option<Header>>> + Send + 'a>>;

pub(super) async fn start_next_header_read<'a, R>(reader: &'a mut R) -> PendingHeaderRead<'a>
where
    R: AsyncRead + Unpin + Send + 'a,
{
    let mut future: PendingHeaderRead<'a> = Box::pin(protocol::reader::read_header(reader));
    let mut ready_result = None;
    poll_fn(|cx| {
        if let Poll::Ready(result) = future.as_mut().poll(cx) {
            ready_result = Some(result);
        }
        Poll::Ready(())
    })
    .await;

    if let Some(result) = ready_result {
        Box::pin(async move { result })
    } else {
        future
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::task::Context;

    use tokio::io::{AsyncWriteExt, ReadBuf};

    use crate::protocol::opcode::OpCode;

    fn assert_header_matches(
        header: &Header,
        length: i32,
        request_id: i32,
        response_to: i32,
        op_code: OpCode,
    ) {
        assert_eq!(header.length, length);
        assert_eq!(header.request_id, request_id);
        assert_eq!(header.response_to, response_to);
        assert_eq!(header.op_code, op_code);
    }

    fn encode_header(length: i32, request_id: i32, response_to: i32, op_code: OpCode) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(Header::LENGTH);
        bytes.extend_from_slice(&length.to_le_bytes());
        bytes.extend_from_slice(&request_id.to_le_bytes());
        bytes.extend_from_slice(&response_to.to_le_bytes());
        bytes.extend_from_slice(&(op_code as i32).to_le_bytes());
        bytes
    }

    struct ReadyHeaderReader {
        bytes: Vec<u8>,
        offset: usize,
    }

    impl ReadyHeaderReader {
        fn new(bytes: Vec<u8>) -> Self {
            Self { bytes, offset: 0 }
        }
    }

    impl AsyncRead for ReadyHeaderReader {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            assert!(
                self.offset < self.bytes.len(),
                "reader was polled again after the ready header had already been captured"
            );

            let remaining = &self.bytes[self.offset..];
            let to_copy = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..to_copy]);
            self.offset += to_copy;
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn start_next_header_read_reuses_immediate_result_without_rereading() {
        let mut reader = ReadyHeaderReader::new(encode_header(16, 42, 7, OpCode::Msg));

        let next_header = start_next_header_read(&mut reader).await;
        let header = next_header
            .await
            .expect("header read should succeed")
            .expect("header should be present");

        assert_header_matches(&header, 16, 42, 7, OpCode::Msg);
    }

    #[tokio::test]
    async fn start_next_header_read_waits_for_pending_header_bytes() {
        let (mut reader, mut writer) = tokio::io::duplex(64);
        let next_header = start_next_header_read(&mut reader).await;

        writer
            .write_all(&encode_header(16, 99, 3, OpCode::Msg))
            .await
            .expect("header bytes should be written");
        writer
            .shutdown()
            .await
            .expect("writer should shut down cleanly");

        let header = next_header
            .await
            .expect("pending header read should succeed")
            .expect("header should be present");

        assert_header_matches(&header, 16, 99, 3, OpCode::Msg);
    }

    #[tokio::test]
    async fn start_next_header_read_returns_none_on_clean_eof() {
        let mut reader = tokio::io::empty();
        let next_header = start_next_header_read(&mut reader).await;

        assert!(
            next_header
                .await
                .expect("clean EOF should not be an error")
                .is_none(),
            "clean EOF should surface as no next header"
        );
    }
}
