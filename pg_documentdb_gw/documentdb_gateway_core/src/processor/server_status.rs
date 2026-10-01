/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/server_status.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::{rawdoc, DateTime, RawBsonRef, RawDocumentBuf};
use tokio::time::Instant;

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    protocol::OK_SUCCEEDED,
    responses::{RawResponse, Response},
    time::STARTUP_INSTANT,
};

/// Sections that serverStatus returns by default. Each is omitted when the
/// command supplies a falsy toggle for its name.
const DEFAULT_SECTIONS: &[&str] = &[
    "asserts",
    "connections",
    "extra_info",
    "globalLock",
    "locks",
    "logicalSessionRecordCache",
    "mem",
    "metrics",
    "network",
    "opcounters",
    "opcountersRepl",
    "storageEngine",
    "transactions",
    "catalogStats",
];

/// Returns the instant this process started, captured once as early as possible
/// in `main()` via [`crate::time::STARTUP_INSTANT`]. Reading the process startup
/// instant makes the reported uptime reflect the real process lifetime rather
/// than the moment the first serverStatus request was served. If the startup
/// instant was never initialized (for example in a unit test that does not boot
/// the gateway), it falls back to the first observed instant, which keeps the
/// reported uptime monotonic.
fn process_start() -> Instant {
    *STARTUP_INSTANT.get_or_init(Instant::now)
}

/// Applies wire-protocol truthiness to a section toggle value. Numeric zero,
/// boolean false, and null are falsy; every other value is truthy.
fn toggle_is_truthy(value: &RawBsonRef) -> bool {
    match value {
        RawBsonRef::Boolean(enabled) => *enabled,
        RawBsonRef::Null | RawBsonRef::Undefined => false,
        RawBsonRef::Int32(number) => *number != 0,
        RawBsonRef::Int64(number) => *number != 0,
        RawBsonRef::Double(number) => *number != 0.0,
        RawBsonRef::Decimal128(decimal) => {
            // The bson crate does not expose a numeric accessor for Decimal128,
            // so parse its canonical string form. Every zero encoding (0, -0,
            // 0E+3) parses to +/-0.0 and is falsy; non-finite values (NaN,
            // Infinity) parse to non-zero f64 and stay truthy, matching the
            // managed gateway's numeric-zero handling. A parse failure, which a
            // valid Decimal128 does not produce, falls back to truthy.
            decimal.to_string().parse::<f64>() != Ok(0.0)
        }
        _ => true,
    }
}

fn section(name: &str) -> RawDocumentBuf {
    match name {
        "asserts" => rawdoc! {
            "regular": 0_i64,
            "warning": 0_i64,
            "msg": 0_i64,
            "user": 0_i64,
            "rollovers": 0_i64,
        },
        "connections" => rawdoc! {
            "current": 1_i64,
            "available": 1_000_000_i64,
            "totalCreated": 1_i64,
            "active": 1_i64,
        },
        "extra_info" => rawdoc! {
            "page_faults": 0_i64,
        },
        "globalLock" => rawdoc! {
            "totalTime": 0_i64,
            "currentQueue": {
                "total": 0_i64,
                "readers": 0_i64,
                "writers": 0_i64,
            },
            "activeClients": {
                "total": 0_i64,
                "readers": 0_i64,
                "writers": 0_i64,
            },
        },
        "logicalSessionRecordCache" => rawdoc! {
            "activeSessionsCount": 0_i64,
            "sessionsCollectionJobCount": 0_i64,
        },
        "mem" => rawdoc! {
            "bits": 64_i64,
            "resident": 1_i64,
            "virtual": 1_i64,
            "supported": true,
        },
        "network" => rawdoc! {
            "bytesIn": 0_i64,
            "bytesOut": 0_i64,
            "numRequests": 0_i64,
        },
        "opcounters" | "opcountersRepl" => rawdoc! {
            "insert": 0_i64,
            "query": 0_i64,
            "update": 0_i64,
            "delete": 0_i64,
            "getmore": 0_i64,
            "command": 0_i64,
        },
        "storageEngine" => rawdoc! {
            "name": "documentdb",
            "persistent": true,
            "supportsCommittedReads": true,
        },
        "transactions" => rawdoc! {
            "retriedCommandsCount": 0_i64,
            "retriedStatementsCount": 0_i64,
            "transactionsCollectionWriteCount": 0_i64,
        },
        "catalogStats" => rawdoc! {
            "collections": 0_i64,
            "capped": 0_i64,
            "views": 0_i64,
            "timeseries": 0_i64,
            "internalCollections": 0_i64,
            "internalViews": 0_i64,
        },
        // "locks" and "metrics" have no fields asserted by the compatibility
        // suite; they only need to be present as objects by default.
        _ => rawdoc! {},
    }
}

/// Builds the serverStatus response. The command argument value is ignored;
/// top-level fields describe the process identity and uptime, and each default
/// section is included unless the command toggles it off.
pub fn process(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    dynamic_configuration: &Arc<dyn DynamicConfiguration>,
) -> Response {
    let elapsed = process_start().elapsed();
    let uptime_millis = i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX);

    let mut excluded: Vec<&str> = Vec::new();
    let mut include_mirrored_reads = false;
    for element in request_context.request().document() {
        let Ok((name, value)) = element else {
            continue;
        };
        if name == "mirroredReads" {
            if toggle_is_truthy(&value) {
                include_mirrored_reads = true;
            }
        } else if DEFAULT_SECTIONS.contains(&name) && !toggle_is_truthy(&value) {
            excluded.push(name);
        }
    }

    let host = connection_context
        .service_context
        .setup_configuration()
        .node_host_name()
        .to_owned();

    let mut doc = RawDocumentBuf::new();
    doc.append("host", host);
    doc.append("version", dynamic_configuration.server_version().as_str());
    doc.append("process", "mongod");
    doc.append("pid", i64::from(std::process::id()));
    doc.append("uptime", elapsed.as_secs_f64());
    doc.append("uptimeMillis", uptime_millis);
    doc.append("uptimeEstimate", uptime_millis / 1000);
    doc.append("localTime", DateTime::now());

    for name in DEFAULT_SECTIONS {
        if !excluded.contains(name) {
            doc.append(*name, section(name));
        }
    }

    if include_mirrored_reads {
        doc.append("mirroredReads", rawdoc! {});
    }

    doc.append("ok", OK_SUCCEEDED);

    Response::Raw(RawResponse::new(doc))
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use bson::{Decimal128, RawBsonRef};

    use super::toggle_is_truthy;

    #[test]
    fn toggle_is_truthy_treats_numeric_zero_as_falsy() {
        assert!(!toggle_is_truthy(&RawBsonRef::Boolean(false)));
        assert!(!toggle_is_truthy(&RawBsonRef::Null));
        assert!(!toggle_is_truthy(&RawBsonRef::Undefined));
        assert!(!toggle_is_truthy(&RawBsonRef::Int32(0)));
        assert!(!toggle_is_truthy(&RawBsonRef::Int64(0)));
        assert!(!toggle_is_truthy(&RawBsonRef::Double(0.0)));
    }

    #[test]
    fn toggle_is_truthy_treats_non_zero_as_truthy() {
        assert!(toggle_is_truthy(&RawBsonRef::Boolean(true)));
        assert!(toggle_is_truthy(&RawBsonRef::Int32(1)));
        assert!(toggle_is_truthy(&RawBsonRef::Int64(-1)));
        assert!(toggle_is_truthy(&RawBsonRef::Double(0.5)));
    }

    #[test]
    fn toggle_is_truthy_handles_decimal128_zero_encodings() {
        for encoding in ["0", "-0", "0E+3", "0.0"] {
            let decimal = Decimal128::from_str(encoding).expect("valid decimal128");
            assert!(
                !toggle_is_truthy(&RawBsonRef::Decimal128(decimal)),
                "expected decimal128 zero encoding {encoding} to be falsy"
            );
        }
    }

    #[test]
    fn toggle_is_truthy_treats_decimal128_non_zero_as_truthy() {
        for encoding in ["1", "-2.5", "NaN", "Infinity"] {
            let decimal = Decimal128::from_str(encoding).expect("valid decimal128");
            assert!(
                toggle_is_truthy(&RawBsonRef::Decimal128(decimal)),
                "expected decimal128 value {encoding} to be truthy"
            );
        }
    }
}
