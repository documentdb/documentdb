/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/sql_commenter.rs
 *
 * SQLCommenter-style trace correlation for data-path queries.
 *
 *-------------------------------------------------------------------------
 */

//! Builds W3C `traceparent` SQL comments for query/Postgres-log correlation.
//!
//! The comment follows the `SQLCommenter` convention and is derived from the
//! currently active span so a sampled query can be matched to the Postgres log
//! line it produced. See <https://google.github.io/sqlcommenter/>.
//!
//! The comment is only attached to queries that bypass the prepared-statement
//! cache (executed as ephemeral unnamed statements), so it never causes
//! statement-cache churn on the hot path.

use opentelemetry::trace::{TraceContextExt, TraceFlags};
use tracing_opentelemetry::OpenTelemetrySpanExt;

/// Builds a `SQLCommenter` trailing comment from the currently active span.
///
/// Returns `None` when no valid, sampled span context is active (e.g. trace
/// export is disabled or the trace was not sampled), so the caller falls back to
/// the normal cached-statement path. Because emission is gated on the sampling
/// decision, the trace sampler ratio controls how many queries are commented.
#[must_use]
pub fn current_trace_comment() -> Option<String> {
    let context = tracing::Span::current().context();
    let span = context.span();
    let span_context = span.span_context();

    if !span_context.is_valid() || !span_context.is_sampled() {
        return None;
    }

    Some(format_traceparent_comment(
        &span_context.trace_id().to_string(),
        &span_context.span_id().to_string(),
        span_context.trace_flags(),
    ))
}

/// Formats a W3C `traceparent` value as a `SQLCommenter` block comment.
///
/// The inputs are hex trace/span identifiers and a flag byte, so the result can
/// never contain a `*/` sequence or any user-derived data.
fn format_traceparent_comment(trace_id: &str, span_id: &str, flags: TraceFlags) -> String {
    format!(
        "/*traceparent='00-{trace_id}-{span_id}-{:02x}'*/",
        flags.to_u8()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_sampled_traceparent_comment() {
        let comment = format_traceparent_comment(
            "0af7651916cd43dd8448eb211c80319c",
            "b7ad6b7169203331",
            TraceFlags::SAMPLED,
        );
        assert_eq!(
            comment,
            "/*traceparent='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'*/"
        );
    }

    #[test]
    fn traceparent_value_has_no_block_comment_terminator() {
        let comment = format_traceparent_comment(
            "0af7651916cd43dd8448eb211c80319c",
            "b7ad6b7169203331",
            TraceFlags::SAMPLED,
        );
        let value = comment
            .strip_prefix("/*traceparent='")
            .and_then(|s| s.strip_suffix("'*/"))
            .expect("comment should be wrapped in the expected delimiters");
        assert!(!value.contains("*/"));
    }

    #[test]
    fn current_trace_comment_is_none_without_active_otel_span() {
        // No OpenTelemetry layer is installed in unit tests, so the ambient span
        // has no valid span context and no comment is produced.
        assert!(current_trace_comment().is_none());
    }
}
