/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/message.rs
 *
 *-------------------------------------------------------------------------
 */

use std::io::Cursor;

use ::bson::RawDocument;
use bitflags::bitflags;

use crate::{
    bson,
    error::DocumentDBError,
    protocol::{reader::str_from_u8_nul_utf8, util::SyncLittleEndianRead},
};

#[derive(Debug)]
pub struct Message<'a> {
    pub(crate) _response_to: i32,
    pub(crate) flags: MessageFlags,
    pub(crate) sections: Vec<MessageSection<'a>>,
    pub(crate) _checksum: Option<u32>,
    pub(crate) _request_id: Option<i32>,
}

impl<'a> Message<'a> {
    /// # Errors
    /// Returns error if the operation fails.
    pub fn read_from_op_msg(
        mut reader: Cursor<&'a [u8]>,
        response_to: i32,
    ) -> Result<Self, DocumentDBError> {
        let message_bytes = *reader.get_ref();

        let raw_flags = reader.read_u32_sync()?;
        validate_required_flag_bits(raw_flags)?;
        let flags = MessageFlags::from_bits_truncate(raw_flags);
        let checksum_present = flags.contains(MessageFlags::CHECKSUM_PRESENT);
        let section_start = usize::try_from(reader.position()).map_err(|error| {
            DocumentDBError::bad_value(format!("OP_MSG section offset is invalid: {error}"))
        })?;

        let section_end = if checksum_present {
            message_bytes
                .len()
                .checked_sub(std::mem::size_of::<u32>())
                .ok_or_else(|| {
                    DocumentDBError::bad_value(
                        "OP_MSG checksumPresent requires four trailing checksum bytes".to_owned(),
                    )
                })
                .and_then(|end| {
                    if end < section_start {
                        Err(DocumentDBError::bad_value(
                            "OP_MSG checksumPresent requires four trailing checksum bytes"
                                .to_owned(),
                        ))
                    } else {
                        Ok(end)
                    }
                })?
        } else {
            message_bytes.len()
        };

        let mut sections = Vec::new();
        let mut section_reader = Cursor::new(&message_bytes[..section_end]);
        section_reader.set_position(reader.position());

        while usize::try_from(section_reader.position()).unwrap_or(usize::MAX) < section_end {
            let section = MessageSection::read(&mut section_reader)?;
            sections.push(section);
        }

        let checksum = if checksum_present {
            reader.set_position(u64::try_from(section_end).map_err(|error| {
                DocumentDBError::bad_value(format!("OP_MSG checksum offset is invalid: {error}"))
            })?);

            Some(reader.read_u32_sync()?)
        } else {
            let position = usize::try_from(section_reader.position()).map_err(|error| {
                DocumentDBError::bad_value(format!("OP_MSG section offset is invalid: {error}"))
            })?;

            let length_remaining = message_bytes.len().saturating_sub(position);
            if length_remaining != 0 {
                return Err(DocumentDBError::bad_value(format!(
                    "Malformed message. Expecting {length_remaining} more bytes of data"
                )));
            }

            None
        };

        // Some drivers don't put the command document first.
        sections.sort_by_key(MessageSection::payload_type);

        Ok(Message {
            _response_to: response_to,
            flags,
            sections,
            _checksum: checksum,
            _request_id: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use ::bson::{rawdoc, RawDocumentBuf};

    fn op_msg_body(flags: MessageFlags, sections: &[Vec<u8>]) -> Vec<u8> {
        raw_op_msg_body(flags.bits(), sections)
    }

    fn raw_op_msg_body(flags: u32, sections: &[Vec<u8>]) -> Vec<u8> {
        let mut bytes = flags.to_le_bytes().to_vec();
        for section in sections {
            bytes.extend_from_slice(section);
        }
        bytes
    }

    fn document_section(document: &RawDocumentBuf) -> Vec<u8> {
        let mut bytes = vec![0];
        bytes.extend_from_slice(document.as_bytes());
        bytes
    }

    fn sequence_section(
        identifier: &str,
        documents: &[&RawDocumentBuf],
        extra_size: i32,
    ) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(identifier.as_bytes());
        payload.push(0);
        for document in documents {
            payload.extend_from_slice(document.as_bytes());
        }
        let size = i32::try_from(std::mem::size_of::<i32>() + payload.len())
            .expect("sequence payload fits in i32")
            + extra_size;
        let mut bytes = vec![1];
        bytes.extend_from_slice(&size.to_le_bytes());
        bytes.extend_from_slice(&payload);
        bytes
    }

    #[test]
    fn checksum_present_reads_trailing_checksum() {
        let command = rawdoc! { "find": "users", "$db": "db" };
        let mut body = op_msg_body(
            MessageFlags::CHECKSUM_PRESENT,
            &[document_section(&command)],
        );
        body.extend_from_slice(&0x1234_5678_u32.to_le_bytes());

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect("message with checksum should parse");
    }

    #[test]
    fn checksum_present_rejects_missing_checksum() {
        let command = rawdoc! { "find": "users", "$db": "db" };
        let body = op_msg_body(
            MessageFlags::CHECKSUM_PRESENT,
            &[document_section(&command)],
        );

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect_err("checksumPresent without checksum should fail");
    }

    #[test]
    fn checksum_present_rejects_truncated_checksum() {
        let command = rawdoc! { "find": "users", "$db": "db" };
        let mut body = op_msg_body(
            MessageFlags::CHECKSUM_PRESENT,
            &[document_section(&command)],
        );
        body.extend_from_slice(&[1, 2]);

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect_err("truncated checksum should fail");
    }

    #[test]
    fn checksum_present_rejects_sequence_that_consumes_checksum() {
        let command = rawdoc! { "insert": "users", "$db": "db" };
        let document = rawdoc! { "_id": 1_i32 };
        let mut body = op_msg_body(
            MessageFlags::CHECKSUM_PRESENT,
            &[
                document_section(&command),
                sequence_section("documents", &[&document], 4),
            ],
        );
        body.extend_from_slice(&0x1234_5678_u32.to_le_bytes());

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect_err("document sequence cannot include checksum bytes");
    }

    #[test]
    fn rejects_unknown_required_flag_bits() {
        let command = rawdoc! { "find": "users", "$db": "db" };
        let unknown_required_flag = 0x0000_0004_u32;
        let body = raw_op_msg_body(unknown_required_flag, &[document_section(&command)]);

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect_err("unknown required OP_MSG flags must be rejected");
    }

    #[test]
    fn ignores_unknown_optional_flag_bits() {
        let command = rawdoc! { "find": "users", "$db": "db" };
        let unknown_optional_flag = 0x0002_0000_u32;
        let body = raw_op_msg_body(unknown_optional_flag, &[document_section(&command)]);

        Message::read_from_op_msg(Cursor::new(body.as_slice()), 0)
            .expect("unknown optional OP_MSG flags should be ignored");
    }
}

/// Represents a section as defined by the `OP_MSG` definition in the driver.
#[derive(Debug)]
pub(crate) enum MessageSection<'a> {
    Document(&'a RawDocument),
    Sequence {
        _size: i32,
        _identifier: &'a str,
        documents: &'a [u8],
    },
}

impl MessageSection<'_> {
    /// Reads bytes from `reader` and deserializes them into a `MessageSection`.
    ///
    /// # Errors
    /// Returns error if the operation fails.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "protocol sizes fit in i32/usize"
    )]
    fn read<'b>(reader: &mut Cursor<&'b [u8]>) -> Result<MessageSection<'b>, DocumentDBError> {
        let payload_type = reader.read_u8_sync()?;

        if payload_type == 0 {
            let (doc, _) = bson::read_document_bytes(reader)?;

            return Ok(MessageSection::Document(doc));
        }
        if payload_type != 1 {
            return Err(DocumentDBError::bad_value(format!(
                "Unsupported OP_MSG section payload type {payload_type}"
            )));
        }

        let size = reader.read_i32_sync()?;
        let size = usize::try_from(size).map_err(|error| {
            DocumentDBError::bad_value(format!("Document sequence size is negative: {error}"))
        })?;

        if size < std::mem::size_of::<i32>() {
            return Err(DocumentDBError::bad_value(format!(
                "Document sequence size {size} is smaller than the size field"
            )));
        }

        let payload_len = size - std::mem::size_of::<i32>();
        let payload_start = usize::try_from(reader.position()).map_err(|error| {
            DocumentDBError::bad_value(format!("Document sequence offset is invalid: {error}"))
        })?;

        let end = payload_start.checked_add(payload_len).ok_or_else(|| {
            DocumentDBError::bad_value("Document sequence size overflows message".to_owned())
        })?;

        if reader.get_ref().len() < end {
            return Err(DocumentDBError::bad_value(format!(
                "Document sequence extends beyond message: end {end}, len {}",
                reader.get_ref().len()
            )));
        }

        let identifier_start = usize::try_from(reader.position()).map_err(|error| {
            DocumentDBError::bad_value(format!("Document sequence offset is invalid: {error}"))
        })?;

        if identifier_start > end {
            return Err(DocumentDBError::bad_value(format!(
                "Document sequence identifier starts beyond section: position {identifier_start}, end {end}"
            )));
        }
        let (identifier, id_size) = str_from_u8_nul_utf8(&reader.get_ref()[identifier_start..end])?;
        reader.set_position(reader.position() + id_size as u64 + 1);

        let pos = reader.position() as usize;
        if pos > end {
            return Err(DocumentDBError::bad_value(format!(
                "Document sequence identifier extends beyond section: position {pos}, end {end}"
            )));
        }

        let documents = &reader.get_ref()[pos..end];
        reader.set_position(u64::try_from(end).map_err(|error| {
            DocumentDBError::bad_value(format!("Document sequence end offset is invalid: {error}"))
        })?);

        Ok(MessageSection::Sequence {
            _size: i32::try_from(size).map_err(|error| {
                DocumentDBError::bad_value(format!("Document sequence size is too large: {error}"))
            })?,
            _identifier: identifier,
            documents,
        })
    }

    const fn payload_type(&self) -> i32 {
        match self {
            Self::Document(_) => 0,
            Self::Sequence { .. } => 1,
        }
    }
}

fn validate_required_flag_bits(raw_flags: u32) -> Result<(), DocumentDBError> {
    const REQUIRED_FLAG_MASK: u32 = 0x0000_FFFF;
    const KNOWN_REQUIRED_FLAGS: u32 =
        MessageFlags::CHECKSUM_PRESENT.bits() | MessageFlags::MORE_TO_COME.bits();

    let unknown_required_flags = raw_flags & REQUIRED_FLAG_MASK & !KNOWN_REQUIRED_FLAGS;
    if unknown_required_flags != 0 {
        return Err(DocumentDBError::bad_value(format!(
            "OP_MSG contains unknown required flag bits: 0x{unknown_required_flags:04X}"
        )));
    }

    Ok(())
}

bitflags! {
    /// Represents the bitwise flags for an `OP_MSG` as defined in the c driver.
    pub(crate) struct MessageFlags: u32 {
        const NONE             = 0b_0000_0000_0000_0000_0000_0000_0000_0000;
        const CHECKSUM_PRESENT = 0b_0000_0000_0000_0000_0000_0000_0000_0001;
        const MORE_TO_COME     = 0b_0000_0000_0000_0000_0000_0000_0000_0010;
        const EXHAUST_ALLOWED  = 0b_0000_0000_0000_0001_0000_0000_0000_0000;
    }
}
