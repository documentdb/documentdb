/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod docdb_openssl;
mod tcp_listener;
mod tls;

pub use tcp_listener::create_tcp_listeners;
pub use tls::TlsProvider;
