/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/read_preference.rs
 *
 *-------------------------------------------------------------------------
 */

use std::str::FromStr;

use crate::{
    error::{DocumentDBError, ErrorCode, Result},
    protocol::bson_scanner,
};

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
    #[expect(
        clippy::too_many_lines,
        reason = "complex read preference parsing logic"
    )]
    pub(super) fn parse(raw_document: Option<&[u8]>) -> Result<()> {
        match raw_document {
            None => Err(DocumentDBError::documentdb_error(
                ErrorCode::FailedToParse,
                "'$readPreference' must be a document".to_owned(),
            )),
            Some(doc_bytes) => {
                let mut read_preference_mode: Option<ReadPreferenceMode> = None;
                let mut max_staleness_seconds: Option<i32> = None;
                let mut hedge: Option<bool> = None;

                bson_scanner::scan_document(doc_bytes, |field| {
                    let key = field.name_str().ok_or_else(|| {
                        DocumentDBError::documentdb_error(
                            ErrorCode::FailedToParse,
                            "Read preference field name is not valid UTF-8".to_owned(),
                        )
                    })?;

                    match key {
                        "mode" => {
                            if read_preference_mode.is_some() {
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::FailedToParse,
                                    "'mode' field is already specified".to_owned(),
                                ));
                            }

                            let mode_str = field.as_str().ok_or_else(|| {
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

                            let seconds = field.as_i32().ok_or_else(|| {
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

                            hedge = Self::parse_hedge(field.as_embedded_document_bytes())?;
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
                    Ok(())
                })?;

                let read_preference_mode = read_preference_mode.ok_or_else(|| {
                    DocumentDBError::documentdb_error(
                        ErrorCode::FailedToParse,
                        "'mode' field is required".to_owned(),
                    )
                })?;

                if read_preference_mode == ReadPreferenceMode::Primary
                    && max_staleness_seconds.is_some()
                {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::FailedToParse,
                        "mode 'primary' does not allow for 'maxStalenessSeconds'".to_owned(),
                    ));
                }

                if read_preference_mode == ReadPreferenceMode::Primary && hedge.is_some() {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::FailedToParse,
                        "mode 'primary' does not allow for 'hedge'".to_owned(),
                    ));
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

    fn parse_hedge(raw_document: Option<&[u8]>) -> Result<Option<bool>> {
        let hedge_doc = raw_document.ok_or_else(|| {
            DocumentDBError::documentdb_error(
                ErrorCode::FailedToParse,
                "'hedge' field must be a document".to_owned(),
            )
        })?;

        let mut hedge = None;
        bson_scanner::scan_document(hedge_doc, |field| {
            let key = field.name_str().ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::FailedToParse,
                    "Hedge field name is not valid UTF-8".to_owned(),
                )
            })?;

            if key == "enabled" {
                hedge = Some(field.as_bool().ok_or_else(|| {
                    DocumentDBError::documentdb_error(
                        ErrorCode::FailedToParse,
                        "'enabled' field in 'hedge' must be a boolean".to_owned(),
                    )
                })?);
            }
            Ok(())
        })?;
        Ok(hedge)
    }
}

#[cfg(test)]
mod tests {
    use bson::rawdoc;

    use crate::{
        error::ErrorCode,
        requests::{read_preference::ReadPreference, read_preference::ReadPreferenceMode},
    };

    #[test]
    fn parse_document_bytes_accepts_primary() {
        let doc = rawdoc! { "mode": "primary" };

        ReadPreference::parse(Some(doc.as_bytes())).unwrap();
    }

    #[test]
    fn parse_document_bytes_rejects_missing_mode() {
        let doc = rawdoc! { "hedge": { "enabled": false } };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::FailedToParse);
    }

    #[test]
    fn parse_document_bytes_rejects_primary_with_max_staleness() {
        let doc = rawdoc! { "mode": "primary", "maxStalenessSeconds": 10_i32 };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::FailedToParse);
    }

    #[test]
    fn parse_document_bytes_rejects_secondary() {
        let doc = rawdoc! { "mode": "secondary" };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::FailedToSatisfyReadPreference);
    }

    #[test]
    fn parse_document_bytes_rejects_hedge_enabled_true() {
        let doc = rawdoc! {
            "mode": "nearest",
            "hedge": { "enabled": true },
        };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::BadValue);
    }

    #[test]
    fn parse_document_bytes_rejects_hedge_array() {
        let doc = rawdoc! {
            "mode": "nearest",
            "hedge": [],
        };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::FailedToParse);
    }

    #[test]
    fn parse_document_bytes_rejects_tags() {
        let doc = rawdoc! {
            "mode": "nearest",
            "tags": [],
        };

        let error = ReadPreference::parse(Some(doc.as_bytes())).unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::FailedToSatisfyReadPreference);
    }

    #[test]
    fn parse_mode_keeps_existing_case_insensitive_mapping() {
        assert_eq!(
            "primaryPreferred".parse::<ReadPreferenceMode>().unwrap(),
            ReadPreferenceMode::PrimaryPreferred
        );
    }
}
