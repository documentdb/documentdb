/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/context_propagation.rs
 *
 * Inbound W3C trace-context propagation for the client -> gateway hop.
 *
 *-------------------------------------------------------------------------
 */

//! Extracts W3C trace context that a client passes in a request `comment`.
//!
//! The wire protocol has no HTTP-style headers, so a client that already owns a
//! distributed trace can carry it into the gateway by setting the request's
//! `comment` field to a JSON object containing a `traceparent` value. When that
//! context is present, the gateway's root span is re-parented to it so the
//! gateway (and the downstream `postgres.execute` span it produces) appear under
//! the caller's trace.
//!
//! Provider-specific context handling is supplied by a process-wide
//! [`TraceContextBridge`].

use std::{fmt::Debug, sync::OnceLock};

use serde_json::Value;

/// Adapter implemented by the configured distributed tracing provider.
pub trait TraceContextBridge: Send + Sync + Debug {
    /// Sets the remote W3C parent on `span`, returning whether it was valid.
    fn set_parent(&self, span: &tracing::Span, traceparent: &str) -> bool;
}

static TRACE_CONTEXT_BRIDGE: OnceLock<&'static dyn TraceContextBridge> = OnceLock::new();

/// Installs the process-wide distributed trace-context bridge.
///
/// Returns `false` when a bridge was already installed.
#[must_use]
pub fn install_trace_context_bridge(bridge: &'static dyn TraceContextBridge) -> bool {
    TRACE_CONTEXT_BRIDGE.set(bridge).is_ok()
}

/// Extracts a `traceparent` from a request `comment` field and asks the
/// configured provider bridge to attach it to `span`.
///
/// The expected shape is `{"traceparent": "00-<trace_id>-<span_id>-<flags>"}`.
/// A plain user comment, malformed JSON, invalid context, or absent provider
/// leaves the span unchanged.
#[must_use]
pub fn set_parent_from_comment(span: &tracing::Span, comment: &str) -> bool {
    let Ok(json) = serde_json::from_str::<Value>(comment) else {
        return false;
    };
    let Some(traceparent) = json.get("traceparent").and_then(Value::as_str) else {
        return false;
    };
    TRACE_CONTEXT_BRIDGE
        .get()
        .is_some_and(|bridge| bridge.set_parent(span, traceparent))
}

/// Marks a span as failed using the provider-neutral status field.
pub fn mark_span_error(span: &tracing::Span) {
    span.record("span.status_code", "error");
}
