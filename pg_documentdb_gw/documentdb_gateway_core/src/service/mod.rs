/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod connection_loop;
mod docdb_openssl;
mod tcp_listener;
mod tls;

pub(crate) use connection_loop::handle_stream;
pub use tcp_listener::create_tcp_listeners;
pub use tls::TlsProvider;
