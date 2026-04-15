/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/stream_driver.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::io::{AsyncRead, AsyncWrite};

use crate::{
    context::ConnectionContext, postgres::PgDataClient, responses,
    service::connection_loop::read_ahead, service::connection_loop::request_pipeline,
};

pub async fn handle_stream<T, S>(stream: S, mut connection_context: ConnectionContext)
where
    T: PgDataClient,
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    let connection_activity_id = connection_context.connection_id.to_string();
    let connection_activity_id_as_str = connection_activity_id.as_str();
    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut next_header = read_ahead::start_next_header_read(&mut reader).await;

    loop {
        let next_header_result = next_header.as_mut().await;
        drop(next_header);

        match next_header_result {
            Ok(Some(header)) => {
                let request_activity_id =
                    connection_context.generate_request_activity_id(header.request_id);

                next_header = request_pipeline::handle_message::<T, _, _>(
                    &mut connection_context,
                    &header,
                    &mut reader,
                    &mut writer,
                    &request_activity_id,
                )
                .await;
            }

            Ok(None) => {
                tracing::info!(
                    activity_id = connection_activity_id_as_str,
                    "Connection closed."
                );
                break;
            }

            Err(error) => {
                if let Err(write_error) = responses::writer::write_error_without_header(
                    &connection_context,
                    error,
                    &mut writer,
                    connection_activity_id_as_str,
                )
                .await
                {
                    tracing::warn!(
                        activity_id = connection_activity_id_as_str,
                        "Couldn't reply with error {write_error:?}."
                    );
                    break;
                }

                next_header = read_ahead::start_next_header_read(&mut reader).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::{
        io,
        pin::Pin,
        sync::{Arc, Mutex},
        task::{Context, Poll},
    };

    use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadBuf};

    use crate::{
        error::ErrorCode,
        postgres::DocumentDBDataClient,
        testing::{
            assert_error_response, assert_success_response, build_op_msg_request,
            decode_op_msg_responses, logout_document, test_connection_context,
            TestDynamicConfiguration,
        },
    };

    #[derive(Debug)]
    enum ReadState {
        ErrorOnce,
        Eof,
    }

    #[derive(Clone, Debug)]
    struct ErrorSequenceStream {
        read_state: Arc<Mutex<ReadState>>,
        writes: Arc<Mutex<Vec<u8>>>,
        fail_writes: bool,
    }

    impl ErrorSequenceStream {
        fn new(fail_writes: bool) -> Self {
            Self {
                read_state: Arc::new(Mutex::new(ReadState::ErrorOnce)),
                writes: Arc::new(Mutex::new(Vec::new())),
                fail_writes,
            }
        }

        fn written_bytes(&self) -> Vec<u8> {
            self.writes
                .lock()
                .expect("write buffer lock should not be poisoned")
                .clone()
        }
    }

    impl AsyncRead for ErrorSequenceStream {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            let mut state = self
                .read_state
                .lock()
                .expect("read state lock should not be poisoned");

            match *state {
                ReadState::ErrorOnce => {
                    *state = ReadState::Eof;
                    drop(state);
                    Poll::Ready(Err(io::Error::other("synthetic read failure")))
                }
                ReadState::Eof => Poll::Ready(Ok(())),
            }
        }
    }

    impl AsyncWrite for ErrorSequenceStream {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            if self.fail_writes {
                return Poll::Ready(Err(io::Error::other("synthetic write failure")));
            }

            self.writes
                .lock()
                .expect("write buffer lock should not be poisoned")
                .extend_from_slice(buf);

            Poll::Ready(Ok(buf.len()))
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn handle_stream_processes_back_to_back_auth_requests_in_order() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let (mut client_stream, server_stream) = tokio::io::duplex(4096);

        let server_task = tokio::spawn(async move {
            handle_stream::<DocumentDBDataClient, _>(server_stream, connection_context).await;
        });

        let first_request = logout_document();
        client_stream
            .write_all(&build_op_msg_request(&first_request, 81))
            .await
            .expect("first request should be written");
        let second_request = logout_document();
        client_stream
            .write_all(&build_op_msg_request(&second_request, 82))
            .await
            .expect("second request should be written");
        client_stream
            .shutdown()
            .await
            .expect("client writer should shut down cleanly");

        let mut response_bytes = Vec::new();
        client_stream
            .read_to_end(&mut response_bytes)
            .await
            .expect("client reader should drain responses");
        server_task
            .await
            .expect("server task should finish without panicking");

        let responses = decode_op_msg_responses(&response_bytes);
        assert_eq!(
            responses.len(),
            2,
            "two requests should yield two responses"
        );
        assert_eq!(responses[0].0.response_to, 81);
        assert_eq!(responses[1].0.response_to, 82);
        assert_success_response(&responses[0].1);
        assert_success_response(&responses[1].1);
    }

    #[tokio::test]
    async fn handle_stream_exits_cleanly_on_immediate_eof() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let (mut client_stream, server_stream) = tokio::io::duplex(1024);

        let server_task = tokio::spawn(async move {
            handle_stream::<DocumentDBDataClient, _>(server_stream, connection_context).await;
        });

        client_stream
            .shutdown()
            .await
            .expect("client writer should shut down cleanly");

        let mut response_bytes = Vec::new();
        client_stream
            .read_to_end(&mut response_bytes)
            .await
            .expect("client reader should drain responses");
        server_task
            .await
            .expect("server task should finish without panicking");

        assert!(
            response_bytes.is_empty(),
            "no responses should be written when the connection closes before any request"
        );
    }

    #[tokio::test]
    async fn handle_stream_writes_error_response_after_read_failure() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let stream = ErrorSequenceStream::new(false);
        let stream_handle = stream.clone();

        handle_stream::<DocumentDBDataClient, _>(stream, connection_context).await;

        let responses = decode_op_msg_responses(&stream_handle.written_bytes());
        assert_eq!(
            responses.len(),
            1,
            "read failure should yield one error response"
        );
        assert_error_response(&responses[0].1, ErrorCode::InternalError);
    }

    #[tokio::test]
    async fn handle_stream_stops_when_error_reply_cannot_be_written() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let stream = ErrorSequenceStream::new(true);
        let stream_handle = stream.clone();

        handle_stream::<DocumentDBDataClient, _>(stream, connection_context).await;

        assert!(
            stream_handle.written_bytes().is_empty(),
            "write failure while replying to a read error should not leave partial output"
        );
    }
}
