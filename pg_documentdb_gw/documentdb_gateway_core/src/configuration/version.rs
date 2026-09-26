/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/version.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawArrayBuf;

pub const DEFAULT_MAX_WIRE_VERSION: i32 = 21;

const MIN_MAPPED_WIRE_VERSION: i32 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Version {
    FourTwo,
    FourFour,
    Five,
    FiveOne,
    FiveTwo,
    FiveThree,
    Six,
    SixOne,
    SixTwo,
    SixThree,
    Seven,
    SevenOne,
    SevenTwo,
    SevenThree,
    Eight,
    EightOne,
    EightTwo,
    EightThree,
    Nine,
}

impl Version {
    #[must_use]
    pub const fn from_wire(wire: i32) -> Option<Self> {
        match wire {
            8 => Some(Self::FourTwo),
            9 => Some(Self::FourFour),
            13 => Some(Self::Five),
            14 => Some(Self::FiveOne),
            15 => Some(Self::FiveTwo),
            16 => Some(Self::FiveThree),
            17 => Some(Self::Six),
            18 => Some(Self::SixOne),
            19 => Some(Self::SixTwo),
            20 => Some(Self::SixThree),
            21 => Some(Self::Seven),
            22 => Some(Self::SevenOne),
            23 => Some(Self::SevenTwo),
            24 => Some(Self::SevenThree),
            25 => Some(Self::Eight),
            26 => Some(Self::EightOne),
            27 => Some(Self::EightTwo),
            28 => Some(Self::EightThree),
            29 => Some(Self::Nine),
            _ => None,
        }
    }

    #[must_use]
    pub const fn resolve_for_wire(wire: i32) -> Self {
        if let Some(version) = Self::from_wire(wire) {
            return version;
        }

        if wire < MIN_MAPPED_WIRE_VERSION {
            Self::FourTwo
        } else {
            Self::Nine
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::FourTwo => "4.2.0",
            Self::FourFour => "4.4.0",
            Self::Five => "5.0.0",
            Self::FiveOne => "5.1.0",
            Self::FiveTwo => "5.2.0",
            Self::FiveThree => "5.3.0",
            Self::Six => "6.0.0",
            Self::SixOne => "6.1.0",
            Self::SixTwo => "6.2.0",
            Self::SixThree => "6.3.0",
            Self::Seven => "7.0.0",
            Self::SevenOne => "7.1.0",
            Self::SevenTwo => "7.2.0",
            Self::SevenThree => "7.3.0",
            Self::Eight => "8.0.0",
            Self::EightOne => "8.1.0",
            Self::EightTwo => "8.2.0",
            Self::EightThree => "8.3.0",
            Self::Nine => "9.0.0",
        }
    }

    #[must_use]
    pub const fn as_array(self) -> [i32; 4] {
        match self {
            Self::FourTwo => [4, 2, 0, 0],
            Self::FourFour => [4, 4, 0, 0],
            Self::Five => [5, 0, 0, 0],
            Self::FiveOne => [5, 1, 0, 0],
            Self::FiveTwo => [5, 2, 0, 0],
            Self::FiveThree => [5, 3, 0, 0],
            Self::Six => [6, 0, 0, 0],
            Self::SixOne => [6, 1, 0, 0],
            Self::SixTwo => [6, 2, 0, 0],
            Self::SixThree => [6, 3, 0, 0],
            Self::Seven => [7, 0, 0, 0],
            Self::SevenOne => [7, 1, 0, 0],
            Self::SevenTwo => [7, 2, 0, 0],
            Self::SevenThree => [7, 3, 0, 0],
            Self::Eight => [8, 0, 0, 0],
            Self::EightOne => [8, 1, 0, 0],
            Self::EightTwo => [8, 2, 0, 0],
            Self::EightThree => [8, 3, 0, 0],
            Self::Nine => [9, 0, 0, 0],
        }
    }

    #[must_use]
    pub fn as_bson_array(self) -> RawArrayBuf {
        let mut array = RawArrayBuf::new();
        for part in self.as_array() {
            array.push(part);
        }
        array
    }
}

pub const DEFAULT_SERVER_VERSION: &str = Version::Seven.as_str();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_wire_known_mappings() {
        assert_eq!(Version::from_wire(8), Some(Version::FourTwo));
        assert_eq!(Version::from_wire(21), Some(Version::Seven));
        assert_eq!(Version::from_wire(25), Some(Version::Eight));
        assert_eq!(Version::from_wire(27), Some(Version::EightTwo));
        assert_eq!(Version::from_wire(29), Some(Version::Nine));
    }

    #[test]
    fn from_wire_unknown() {
        assert_eq!(Version::from_wire(7), None);
        assert_eq!(Version::from_wire(10), None);
        assert_eq!(Version::from_wire(11), None);
        assert_eq!(Version::from_wire(12), None);
        assert_eq!(Version::from_wire(30), None);
    }

    #[test]
    fn resolve_for_wire_fallbacks() {
        assert_eq!(Version::resolve_for_wire(21), Version::Seven);
        assert_eq!(Version::resolve_for_wire(7), Version::FourTwo);
        assert_eq!(Version::resolve_for_wire(10), Version::Nine);
        assert_eq!(Version::resolve_for_wire(30), Version::Nine);
    }

    #[test]
    fn as_str_and_array_match() {
        assert_eq!(Version::Seven.as_str(), "7.0.0");
        assert_eq!(Version::Seven.as_array(), [7, 0, 0, 0]);
        assert_eq!(Version::EightTwo.as_str(), "8.2.0");
        assert_eq!(Version::EightTwo.as_array(), [8, 2, 0, 0]);
    }
}
