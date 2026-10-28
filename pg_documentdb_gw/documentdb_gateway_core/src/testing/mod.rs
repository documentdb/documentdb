/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/testing/mod.rs
 *
 * Shared testing helpers.
 *
 *-------------------------------------------------------------------------
 */

mod connection_context;
#[cfg(test)]
mod dynamic_configuration;
#[cfg(test)]
mod env_guard;
#[cfg(test)]
pub mod logs;
#[cfg(test)]
mod op_msg;
#[cfg(test)]
mod pool;
mod postgres_row;
#[cfg(test)]
mod request_documents;
#[cfg(test)]
pub mod telemetry;

pub use connection_context::{
    test_connection_context, test_connection_context_with_authentication_manager,
};
#[cfg(test)]
pub use dynamic_configuration::TestDynamicConfiguration;
#[cfg(test)]
pub use env_guard::EnvGuard;
#[cfg(test)]
pub use op_msg::{
    assert_error_response, assert_header_matches, assert_success_response, build_document_section,
    build_document_sequence_section, build_op_msg_parts, build_op_msg_parts_with_sections,
    build_op_msg_request, build_raw_document, decode_op_msg_response, decode_op_msg_responses,
};
#[cfg(test)]
pub use pool::{test_connection_pool, test_setup_configuration};
pub use postgres_row::test_postgres_row;
#[cfg(test)]
pub use request_documents::{
    invalid_transaction_find_document, logout_document, malformed_sasl_start_document,
    ping_document,
};
#[cfg(test)]
pub use telemetry::{MetricKind, RecordingMetricsRecorder, RecordingTelemetryProvider};
