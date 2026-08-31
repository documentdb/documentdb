/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/writer.rs
 *
 *-------------------------------------------------------------------------
 */

//! Response writer adapter that preserves the first incomplete-write error.

use std::{
    pin::Pin,
    task::{Context, Poll},
};

use tokio::io::AsyncWrite;

pub(super) struct FailureTrackingWriter<'a, W> {
    writer: &'a mut W,
    first_error: Option<std::io::Error>,
}

impl<'a, W> FailureTrackingWriter<'a, W> {
    pub(super) const fn new(writer: &'a mut W) -> Self {
        Self {
            writer,
            first_error: None,
        }
    }

    pub(super) fn into_result(self) -> crate::error::Result<()> {
        self.first_error.map_or(Ok(()), |error| Err(error.into()))
    }

    fn record_error(&mut self, error: &std::io::Error) {
        if self.first_error.is_none() {
            self.first_error = Some(std::io::Error::new(error.kind(), error.to_string()));
        }
    }
}

impl<W> AsyncWrite for FailureTrackingWriter<'_, W>
where
    W: AsyncWrite + Unpin,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let result = Pin::new(&mut *self.writer).poll_write(cx, buf);
        match &result {
            Poll::Ready(Err(error)) => self.record_error(error),
            Poll::Ready(Ok(0)) if !buf.is_empty() => self.record_error(&std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "response writer made no progress",
            )),
            _ => {}
        }
        result
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let result = Pin::new(&mut *self.writer).poll_flush(cx);
        if let Poll::Ready(Err(error)) = &result {
            self.record_error(error);
        }
        result
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let result = Pin::new(&mut *self.writer).poll_shutdown(cx);
        if let Poll::Ready(Err(error)) = &result {
            self.record_error(error);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use bson::doc;
    use bytes::Bytes;
    use tokio::time::Instant;

    use super::*;
    use crate::{
        error::ErrorKind,
        postgres::DocumentDBDataClient,
        service::connection_loop::process_request_message,
        testing::{build_op_msg_parts, test_connection_context, TestDynamicConfiguration},
    };

    struct FailingResponseWriter;

    struct ZeroResponseWriter;

    impl AsyncWrite for FailingResponseWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            Poll::Ready(Err(std::io::Error::other("injected write failure")))
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    impl AsyncWrite for ZeroResponseWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            Poll::Ready(Ok(0))
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn process_request_message_reports_incomplete_response_write() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 85);

        let error = process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-write-failure",
            &mut FailingResponseWriter,
        )
        .await
        .expect_err("incomplete response write should be reported");

        assert_eq!(error.kind(), &ErrorKind::Io);
    }
    #[tokio::test]
    async fn process_request_message_reports_zero_progress_response_write() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 86);

        let error = process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-zero-progress-write",
            &mut ZeroResponseWriter,
        )
        .await
        .expect_err("zero-progress response write should be reported");

        assert_eq!(error.kind(), &ErrorKind::Io);
    }
}
