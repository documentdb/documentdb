// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/*-------------------------------------------------------------------------
 * documentdb_gateway_core/src/service/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod connection_loop;
mod docdb_openssl;
mod listener_config;
mod tcp_listener;
mod tls;

pub(crate) use connection_loop::handle_stream;
pub use connection_loop::{
    process_request_message, DefaultRequestRouter, RequestAuthenticationResult, RequestRouter,
};
pub use listener_config::ListenerConfig;
pub use tcp_listener::create_tcp_listeners;
pub use tls::{
    spawn_certificate_reload_task, CertificateBundle, CertificateStorePaths, TlsProvider,
};
