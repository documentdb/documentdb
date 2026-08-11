/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/version.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawArrayBuf;

/// Default `buildInfo.version` (`documentdb.server_version`).
pub const DEFAULT_SERVER_VERSION: &str = "7.0.0";

/// Default `hello` / `isMaster` `maxWireVersion` (`documentdb.max_wire_version`).
pub const DEFAULT_MAX_WIRE_VERSION: i32 = 21;

/// Builds a Mongo-style `versionArray` (four integers) from a dotted version.
/// Missing trailing components are padded with zeros. Non-numeric input falls
/// back to `[7, 0, 0, 0]`.
#[must_use]
pub fn version_array_from_str(version: &str) -> [i32; 4] {
    let mut parts = [0_i32; 4];

    for (i, component) in version.split('.').take(4).enumerate() {
        match component.parse::<i32>() {
            Ok(n) if n >= 0 => parts[i] = n,
            _ => return [7, 0, 0, 0],
        }
    }

    if version.is_empty() {
        [7, 0, 0, 0]
    } else {
        parts
    }
}

/// BSON array form of [`version_array_from_str`].
#[must_use]
pub fn version_bson_array_from_str(version: &str) -> RawArrayBuf {
    let mut array = RawArrayBuf::new();
    for part in version_array_from_str(version) {
        array.push(part);
    }
    array
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_array_pads_to_four() {
        assert_eq!(version_array_from_str("8.0"), [8, 0, 0, 0]);
        assert_eq!(version_array_from_str("8.0.4"), [8, 0, 4, 0]);
        assert_eq!(version_array_from_str("8.0.4.1"), [8, 0, 4, 1]);
    }

    #[test]
    fn version_array_invalid_falls_back() {
        assert_eq!(version_array_from_str("not-a-version"), [7, 0, 0, 0]);
        assert_eq!(version_array_from_str(""), [7, 0, 0, 0]);
    }
}
