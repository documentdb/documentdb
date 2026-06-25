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
//! Outbound correlation on the gateway -> Postgres hop is handled separately by
//! [`super::sql_commenter`].

use opentelemetry::{
    trace::{SpanContext, SpanId, TraceContextExt, TraceFlags, TraceId, TraceState},
    Context,
};
use serde_json::Value;

/// Extracts a parent [`Context`] from a request `comment` field, if it carries a
/// valid W3C `traceparent`.
///
/// The expected shape is `{"traceparent": "00-<trace_id>-<span_id>-<flags>"}`.
/// Anything else — a plain user comment, malformed JSON, an unsupported version,
/// or all-zero identifiers — yields `None` so the request is unaffected and the
/// gateway simply starts a fresh trace. This keeps the feature backward
/// compatible with the user-facing `comment` field.
#[must_use]
pub fn extract_context_from_comment(comment: &str) -> Option<Context> {
    // A non-JSON comment (the common case) fails to parse here and returns
    // early, so plain user comments incur only a cheap parse attempt.
    let json: Value = serde_json::from_str(comment).ok()?;
    let traceparent = json.get("traceparent")?.as_str()?;

    // W3C `traceparent`: version "-" trace-id "-" span-id "-" flags.
    // See <https://www.w3.org/TR/trace-context/#traceparent-header>.
    let parts: Vec<&str> = traceparent.split('-').collect();
    if parts.len() != 4 || parts[0] != "00" {
        return None;
    }

    let trace_id = TraceId::from_hex(parts[1]).ok()?;
    let span_id = SpanId::from_hex(parts[2]).ok()?;
    let flags = TraceFlags::new(u8::from_str_radix(parts[3], 16).ok()?);

    if trace_id == TraceId::INVALID || span_id == SpanId::INVALID {
        return None;
    }

    let span_context = SpanContext::new(trace_id, span_id, flags, true, TraceState::default());
    Some(Context::current().with_remote_span_context(span_context))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_returns_none_for_invalid_traceparent() {
        assert!(extract_context_from_comment(r#"{"traceparent": "invalid"}"#).is_none());
    }

    #[test]
    fn extract_returns_none_when_traceparent_absent() {
        assert!(extract_context_from_comment(r#"{"other": "field"}"#).is_none());
    }

    #[test]
    fn extract_returns_none_for_malformed_json() {
        assert!(extract_context_from_comment("not json").is_none());
    }

    #[test]
    fn extract_returns_none_for_empty_string() {
        assert!(extract_context_from_comment("").is_none());
    }

    #[test]
    fn extract_returns_none_for_wrong_version() {
        // The W3C version field must be "00".
        let comment =
            r#"{"traceparent": "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}"#;
        assert!(extract_context_from_comment(comment).is_none());
    }

    #[test]
    fn extract_returns_none_for_zero_trace_id() {
        let comment =
            r#"{"traceparent": "00-00000000000000000000000000000000-00f067aa0ba902b7-01"}"#;
        assert!(extract_context_from_comment(comment).is_none());
    }

    #[test]
    fn extract_returns_none_for_zero_span_id() {
        let comment =
            r#"{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"}"#;
        assert!(extract_context_from_comment(comment).is_none());
    }

    #[test]
    fn extract_succeeds_with_extra_fields() {
        let comment = r#"{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "other": "data"}"#;
        assert!(extract_context_from_comment(comment).is_some());
    }

    #[test]
    fn extract_preserves_trace_and_span_ids() {
        let comment =
            r#"{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}"#;
        let context =
            extract_context_from_comment(comment).expect("valid traceparent should parse");
        let span = context.span();
        let span_context = span.span_context();

        assert_eq!(
            span_context.trace_id().to_string(),
            "4bf92f3577b34da6a3ce929d0e0e4736"
        );
        assert_eq!(span_context.span_id().to_string(), "00f067aa0ba902b7");
        assert!(span_context.trace_flags().is_sampled());
    }
}
