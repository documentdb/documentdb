/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod docdb_openssl;
mod tls;

pub use tls::TlsProvider;
