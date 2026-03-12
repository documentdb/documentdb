/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/opcode.rs
 *
 *-------------------------------------------------------------------------
 */

/// Wire Protocol OpCodes
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum OpCode {
    Invalid = 0,
    #[deprecated(note = "OP_REPLY Deprecated")]
    Reply = 1,
    #[deprecated(note = "OP_UPDATE Deprecated")]
    Update = 2001,
    #[deprecated(note = "OP_INSERT Deprecated")]
    Insert = 2002,
    Reserved = 2003,
    #[deprecated(note = "OP_QUERY Deprecated")]
    Query = 2004,
    #[deprecated(note = "OP_GET_MORE Deprecated")]
    GetMore = 2005,
    #[deprecated(note = "OP_DELETE Deprecated")]
    Delete = 2006,
    #[deprecated(note = "OP_KILL_CURSORS Deprecated")]
    KillCursors = 2007,
    Command = 2010,
    CommandReply = 2011,
    Compressed = 2012,
    Msg = 2013,
}

impl OpCode {
    #[expect(deprecated)]
    pub fn from_value(code: i32) -> OpCode {
        match code {
            1 => OpCode::Reply,
            2001 => OpCode::Update,
            2002 => OpCode::Insert,
            2003 => OpCode::Reserved,
            2004 => OpCode::Query,
            2005 => OpCode::GetMore,
            2006 => OpCode::Delete,
            2007 => OpCode::KillCursors,
            2010 => OpCode::Command,
            2011 => OpCode::CommandReply,
            2012 => OpCode::Compressed,
            2013 => OpCode::Msg,
            _ => OpCode::Invalid,
        }
    }
}
