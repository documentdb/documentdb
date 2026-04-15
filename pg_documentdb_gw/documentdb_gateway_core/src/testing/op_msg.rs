/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/op_msg.rs
 *
 * Shared OP_MSG framing, response decoding, and BSON helpers for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use bson::{Document, RawDocumentBuf};

use crate::{
    error::ErrorCode,
    protocol::{header::Header, opcode::OpCode},
};

pub fn assert_header_matches(
    header: &Header,
    length: i32,
    request_id: i32,
    response_to: i32,
    op_code: OpCode,
) {
    assert_eq!(header.length, length);
    assert_eq!(header.request_id, request_id);
    assert_eq!(header.response_to, response_to);
    assert_eq!(header.op_code, op_code);
}

pub fn build_raw_document(document: &Document) -> RawDocumentBuf {
    RawDocumentBuf::from_document(document)
        .expect("test document should serialize to RawDocumentBuf")
}

pub fn build_op_msg_parts(document: &Document, request_id: i32) -> (Header, Vec<u8>) {
    let body = build_op_msg_body(document);
    let header = Header {
        length: i32::try_from(Header::LENGTH + body.len())
            .expect("message size should fit into i32"),
        request_id,
        response_to: 0,
        op_code: OpCode::Msg,
    };

    (header, body)
}

pub fn build_op_msg_request(document: &Document, request_id: i32) -> Vec<u8> {
    let (header, body) = build_op_msg_parts(document, request_id);
    let mut bytes = encode_header(
        header.length,
        header.request_id,
        header.response_to,
        header.op_code,
    );
    bytes.extend_from_slice(&body);
    bytes
}

pub fn decode_op_msg_response(bytes: &[u8]) -> (Header, Document) {
    assert!(
        bytes.len() > Header::LENGTH + std::mem::size_of::<u32>(),
        "response bytes should contain a full OP_MSG response"
    );

    let header = Header {
        length: i32::from_le_bytes(bytes[0..4].try_into().expect("length bytes should exist")),
        request_id: i32::from_le_bytes(
            bytes[4..8]
                .try_into()
                .expect("request_id bytes should exist"),
        ),
        response_to: i32::from_le_bytes(
            bytes[8..12]
                .try_into()
                .expect("response_to bytes should exist"),
        ),
        op_code: OpCode::from_value(i32::from_le_bytes(
            bytes[12..16]
                .try_into()
                .expect("op_code bytes should exist"),
        )),
    };

    let expected_len =
        usize::try_from(header.length).expect("response length should fit into usize");
    assert_eq!(
        bytes.len(),
        expected_len,
        "response slice should match encoded header length"
    );
    assert_eq!(header.op_code, OpCode::Msg);
    assert_eq!(
        u32::from_le_bytes(
            bytes[16..20]
                .try_into()
                .expect("message flags bytes should exist")
        ),
        0,
        "response flags should be empty"
    );
    assert_eq!(bytes[20], 0, "response should contain a document section");

    let document = Document::from_reader(&mut std::io::Cursor::new(&bytes[21..]))
        .expect("response BSON should deserialize");

    (header, document)
}

pub fn decode_op_msg_responses(bytes: &[u8]) -> Vec<(Header, Document)> {
    let mut responses = Vec::new();
    let mut offset = 0;

    while offset < bytes.len() {
        let length = usize::try_from(i32::from_le_bytes(
            bytes[offset..offset + 4]
                .try_into()
                .expect("response length bytes should exist"),
        ))
        .expect("response length should fit into usize");
        let end = offset + length;
        responses.push(decode_op_msg_response(&bytes[offset..end]));
        offset = end;
    }

    assert_eq!(
        offset,
        bytes.len(),
        "responses should consume the full byte buffer"
    );

    responses
}

pub fn assert_success_response(document: &Document) {
    assert!(
        (document
            .get_f64("ok")
            .expect("success response should include ok")
            - 1.0)
            .abs()
            < f64::EPSILON,
        "success response should set ok to 1.0"
    );
}

pub fn assert_error_response(document: &Document, expected_code: ErrorCode) {
    let expected_code_name = expected_code.to_string();

    assert!(
        document
            .get_f64("ok")
            .expect("error response should include ok")
            .abs()
            < f64::EPSILON,
        "error response should set ok to 0.0"
    );
    assert_eq!(
        document
            .get_str("codeName")
            .expect("error response should include codeName"),
        expected_code_name
    );
}

fn encode_header(length: i32, request_id: i32, response_to: i32, op_code: OpCode) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(Header::LENGTH);
    bytes.extend_from_slice(&length.to_le_bytes());
    bytes.extend_from_slice(&request_id.to_le_bytes());
    bytes.extend_from_slice(&response_to.to_le_bytes());
    bytes.extend_from_slice(&(op_code as i32).to_le_bytes());
    bytes
}

fn build_op_msg_body(document: &Document) -> Vec<u8> {
    let raw_document = build_raw_document(document);
    let mut bytes =
        Vec::with_capacity(std::mem::size_of::<u32>() + 1 + raw_document.as_bytes().len());
    bytes.extend_from_slice(&0_u32.to_le_bytes());
    bytes.push(0);
    bytes.extend_from_slice(raw_document.as_bytes());
    bytes
}
