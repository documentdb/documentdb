/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/version.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawArrayBuf;

#[derive(Debug)]
pub enum Version {
    FourTwo,
    Five,
    Six,
    Seven,
    Eight,
}

impl Version {
    #[must_use]
    pub fn parse(val: &str) -> Option<Self> {
        match val {
            "4.2" => Some(Self::FourTwo),
            "5.0" => Some(Self::Five),
            "6.0" => Some(Self::Six),
            "7.0" => Some(Self::Seven),
            "8.0" => Some(Self::Eight),
            _ => None,
        }
    }

    #[must_use]
    pub const fn as_str(&self) -> &str {
        match self {
            Self::FourTwo => "4.2.0",
            Self::Five => "5.0.0",
            Self::Six => "6.0.0",
            Self::Seven => "7.0.0",
            Self::Eight => "8.0.0",
        }
    }

    #[must_use]
    pub const fn as_array(&self) -> [i32; 4] {
        match self {
            Self::FourTwo => [4, 2, 0, 0],
            Self::Five => [5, 0, 0, 0],
            Self::Six => [6, 0, 0, 0],
            Self::Seven => [7, 0, 0, 0],
            Self::Eight => [8, 0, 0, 0],
        }
    }

    #[must_use]
    pub fn as_bson_array(&self) -> RawArrayBuf {
        let mut array = RawArrayBuf::new();
        let versions = self.as_array();
        for v in versions {
            array.push(v);
        }
        array
    }

    #[must_use]
    pub const fn max_wire_protocol(&self) -> i32 {
        match self {
            Self::FourTwo => 8,
            Self::Five => 13,
            Self::Six => 17,
            Self::Seven => 21,
            Self::Eight => 25,
        }
    }
}
