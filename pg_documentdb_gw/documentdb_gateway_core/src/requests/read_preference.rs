/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/read_preference.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::error::{DocumentDBError, ErrorCode, Result};
use bson::RawDocument;
use std::str::FromStr;

#[derive(Debug, PartialEq, Eq)]
pub enum ReadPreferenceMode {
    Primary,
    Secondary,
    PrimaryPreferred,
    SecondaryPreferred,
    Nearest,
}

impl FromStr for ReadPreferenceMode {
    type Err = DocumentDBError;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "primary" => Ok(Self::Primary),
            "secondary" => Ok(Self::Secondary),
            "primarypreferred" => Ok(Self::PrimaryPreferred),
            "secondarypreferred" => Ok(Self::SecondaryPreferred),
            "nearest" => Ok(Self::Nearest),
            unsupported => Err(DocumentDBError::documentdb_error(
                ErrorCode::FailedToParse,
                format!("Unsupported read preference mode '{unsupported}'"),
            )),
        }
    }
}

#[derive(Debug)]
pub struct ReadPreference;

impl ReadPreference {
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    ///
    /// # Panics
    ///
    /// Panics if document parsing fails.
    #[expect(
        clippy::too_many_lines,
        reason = "complex read preference parsing logic"
    )]
    #[expect(
        clippy::unwrap_used,
        reason = "read_preference_mode is validated before unwrap"
    )]
    pub fn parse(raw_document: Option<&RawDocument>) -> Result<()> {
        match raw_document {
            None => Err(DocumentDBError::documentdb_error(
                ErrorCode::FailedToParse,
                "'$readPreference' must be a document".to_owned(),
            )),
            Some(doc) => {
                let mut read_preference_mode: Option<ReadPreferenceMode> = None;
                let mut max_staleness_seconds: Option<i32> = None;
                let mut hedge: Option<bool> = None;

                for entry in doc {
                    let (k, v) = entry?;
                    match k {
                        "mode" => {
                            if read_preference_mode.is_some() {
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'mode' field is already specified".to_owned(),
                                ));
                            }

                            let mode_str = v.as_str().ok_or_else(|| {
                                DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'mode' field must be a string".to_owned(),
                                )
                            })?;

                            read_preference_mode = Some(ReadPreferenceMode::from_str(mode_str)?);
                        }
                        "maxStalenessSeconds" => {
                            if max_staleness_seconds.is_some() {
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'maxStalenessSeconds' field is already specified".to_owned(),
                                ));
                            }

                            let seconds = v.as_i32().ok_or_else(|| {
                                DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'maxStalenessSeconds' field must be an integer".to_owned(),
                                )
                            })?;

                            if seconds < 0 {
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'maxStalenessSeconds' field must be non-negative".to_owned(),
                                ));
                            }

                            max_staleness_seconds = Some(seconds);
                        }
                        "hedge" => {
                            if hedge.is_some() {
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'hedge' field is already specified".to_owned(),
                                ));
                            }

                            let hedge_doc = v.as_document().ok_or_else(|| {
                                DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'hedge' field must be a document".to_owned(),
                                )
                            })?;

                            // For simplicity, we only check for the presence of 'enabled' field
                            for hedge_entry in hedge_doc {
                                let (hedge_k, hedge_v) = hedge_entry?;
                                if hedge_k == "enabled" {
                                    hedge = Some(hedge_v.as_bool().ok_or_else(|| {
                                        DocumentDBError::documentdb_error(
                                            ErrorCode::FailedToParse,
                                            "'enabled' field in 'hedge' must be a boolean"
                                                .to_owned(),
                                        )
                                    })?);
                                }
                            }
                        }
                        "tags" => {
                            return Err(DocumentDBError::documentdb_error(
                                ErrorCode::FailedToSatisfyReadPreference,
                                "no server available for query with specified tag set list"
                                    .to_owned(),
                            ));
                        }
                        _ => {}
                    }
                }

                if read_preference_mode.is_none() {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::FailedToParse,
                        "'mode' field is required".to_owned(),
                    ));
                }

                let read_preference_mode = read_preference_mode.unwrap();

                if read_preference_mode == ReadPreferenceMode::Primary {
                    if max_staleness_seconds.is_some() {
                        return Err(DocumentDBError::documentdb_error(
                            ErrorCode::FailedToParse,
                            "mode 'primary' does not allow for 'maxStalenessSeconds'".to_owned(),
                        ));
                    }

                    if hedge.is_some() {
                        return Err(DocumentDBError::documentdb_error(
                            ErrorCode::FailedToParse,
                            "mode 'primary' does not allow for 'hedge'".to_owned(),
                        ));
                    }
                }

                if read_preference_mode == ReadPreferenceMode::Secondary {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::FailedToSatisfyReadPreference,
                        "no server available for query with ReadPreference secondary".to_owned(),
                    ));
                }

                if hedge == Some(true) {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::BadValue,
                        "hedged reads are not supported".to_owned(),
                    ));
                }

                Ok(())
            }
        }
    }
}
