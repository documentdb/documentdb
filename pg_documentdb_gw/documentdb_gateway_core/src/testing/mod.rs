/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/mod.rs
 *
 * Shared testing helpers.
 *
 *-------------------------------------------------------------------------
 */

mod connection_context;
mod dynamic_configuration;
mod env_guard;
mod op_msg;
mod request_documents;
pub mod telemetry;

pub use connection_context::test_connection_context;
pub use dynamic_configuration::TestDynamicConfiguration;
pub use env_guard::EnvGuard;
pub use op_msg::{
    assert_error_response, assert_header_matches, assert_success_response, build_op_msg_parts,
    build_op_msg_request, build_raw_document, decode_op_msg_response, decode_op_msg_responses,
};
pub use request_documents::{
    invalid_transaction_find_document, logout_document, malformed_sasl_start_document,
    ping_document,
};
pub use telemetry::RecordingTelemetryProvider;
