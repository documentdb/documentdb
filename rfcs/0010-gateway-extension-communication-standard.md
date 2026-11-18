---
rfc: 10
title: "Standardization of Gateway / Extension Interaction"
status: Draft
owner: "@seoc01"
issue: "https://github.com/documentdb/documentdb/issues/XXX"
discussion: "https://github.com/documentdb/documentdb/discussions/XXX"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/XXX"
---


# RFC-0010: Standardization of Gateway / Extension Interaction

## Background Information

The DocumentDB Gateway is responsible for working as a layer to translate message from the MongoDB clients applications are using, to the SQL functions defined in the Postgres Extension that implement the command. The MongoDB drivers are generally thought of as sending commands in the form of a single BSON message, like would be sent when using the [`runCommand` feature from a driver](https://github.com/mongodb/specifications/blob/master/source/run-command/run-command.md).  In reality they send a structured datagram that is composed of multiple document sections.

The modifies the command to add the “[global command arguments](https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md#global-command-arguments)” (generally $db and $readPreference) to the BSON message, and convert them into the [OP_MSG](https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md) format to send over the wire. The data within the OP_MSG is divided into sections of type 0 (main command) and type 1 (document sequences). These sections can come in any order in the OP_MSG.

### Main Command: Type 0

The OP_MSG must send exactly one type 0 section that contains the main body of the command, which is sent as a single BSON object, it contains all paramemters for the command (command name, collection, etc) and the global command arguments, except for arguments that are explicitly allowed in the Type 1 sequence based on the command. These arguments are:


|Command	|Document Sequence Identifiers	|
|---	|---	|
|insert	|documents 	|
|update	|updates	|
|delete	|deletes	|
|bulkWrite	|nsInfo, ops	|

These arguments may be passed as part of the main command OR in the Type 1 sections, but not both.

### Document Sequences: Type 1

The Document Sequences represented in section Type 1. Mongo does not document any limits on the number of Type 1 sections, but they are only valid for the commands listed above, so a valid OP_MSG could have at most 2. These sections are represented  as an int32 to describe the size of the sequence data in bytes, a C-String to identify the sequences, then 1 or more BSON documents. Documents are separated using the length field included in the BSON spec. Currently only the commands / identifiers described above are accepted, and any other fields are ignored by the server.

While the main command message is not allowed to exceed 16Mb, these document sequences do not have a size limit, so long as every document within the sequence is unber 16Mb. 

The document sequence within the type 1 sections are stored as individual BSON documents concatenated together, they are not stored as a BSON array (which is an object with the keys ‘0’, ‘1‘, ...). 

### Examples

The OP_MSG format (https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md#op_msg-1): 

```
struct Section {
    uint8 payloadType;
    union payload {
        document  document; // payloadType == 0
        struct sequence { // payloadType == 1
            int32      size;
            cstring    identifier;
            document*  documents;
        };
    };
};

struct OP_MSG {
    struct MsgHeader {
        int32  messageLength;
        int32  requestID;
        int32  responseTo;
        int32  opCode = 2013;
    };
    uint32      flagBits;
    Section+    sections;
    [uint32     checksum;]
};
```

An insert query:

```
db.runCommand({'insert': 'city', 'documents': [
        {'name': 'Seattle', 'state': 'WA'}, 
        {'name': 'Tacoma', 'state': 'WA'}
    ]
})
```

Could be represented without a document sequence as: 

```
int32  messageLength;
int32  requestID;
int32  responseTo;
int32  opCode = 2013;
uint32 flagBits;
uint8  SectionType = 0
bson   document = {
            'insert': 'city', 
           'documents': [
                {'name': 'Seattle', 'state': 'WA'}, 
                {'name': 'Tacoma', 'state': 'WA'}
            ]
           '$db': 'database_name'
           '$readPreference': {...}
        }
```

Or using a document sequence:

```
int32  messageLength;
int32  requestID;
int32  responseTo;
int32  opCode = 2013;
uint32 flagBits;
uint8  SectionType = 1
int32  sectionSize;
cstring sectionIdentifer = 'documents'
bson   bson1 = {'name': 'Seattle', 'state': 'WA'}
bson   bson2 = {'name': 'Seattle', 'state': 'WA'}
uint8  SectionType = 0
bson   document = {
           'insert': 'city', 
           '$db': 'database_name'
           '$readPreference': {...}
        }
```

## Problem 

The purpose of the Gateway is to inspect the incoming message from the client, and call the correct database command to complete the request. Currently the Gateway has different logic depending on which command the user is running, and in some cases will parse the command BSON and extract relevant fields to pass to the API defined in the extension, and in other cases it will pass the command directly. 

This adds additional overhead to the Gateway, and makes any consistent handling of commands in the extension difficult, for example adding a function that runs before every command. We need this functionality to support features like the $currentOp aggregation stage, where the extension will need to be able to filter / group across the commands the user is running. 

With the current approach each command would need a custom implementation to be able to re-construct the original command, and some data for some commands, such as is currently unavailable. 

## Approach

The proposed approach is to set a requirement that every command sent from the client to the Gateway that is implemented in the Postgres extension take in the complete client message.  (Note: commands like `hello` that are implemented only in the Gateway do not apply). 

This sets 2 requirements:

* Every command the Gateway calls MUST have a function that can be called with only the request BSON (OP_MSG Section type 0) as a required parameter, and for operations that optionally take a document sequence (OP_MSG Section Type 1) the command MUST have additional optional positional arguments for the expected document sequence.
* A single client command to the Gateway MUST only call one extension function to implement it.

Many of the core operations within the Gateway currently do this, this RFC recommends updating the current actions that do not, and making it a requirement for any new operations added to the Gateway.

As the document sequences are always optional, any user that does not interact with the gateway (e.g. someone executing the SQL commands directly) can always use the BSON only command operation without needing to construct document sequences if they do not wish to. 

### Alternate Approach

An alternate approach was considered where the gateway took the contents of the document sequences, and inserted them into the command bson as an array instead of sending them as separate components. This would simplify the implementation within the Postgres extension as all commands would have a single request, and they would not need to be aware of how the OP_MSG format splits messages. This would require that the incoming BSON be allowed to exceed 16Mb, which would be acceptable since the 16Mb limit is Mongo defined, and a BSON by itself can be up to 4Gb. 

This is not preferred because it would require additional work at the Gateway layer, where the Gateway may need to create a new several Mb message before passing to the extension, and would prevent the extension from being able to validate the command message is under 16Mb without additional knowledge on how the caller constructed the message.

### Example

A find request in the form:

```
{'find': 'coll', 'filter': {'a':1}, '$db': 'foo'}
```

Must be implemented by the gateway with a single SQL call to the extension, that passes the request  as a single argument

```
select documentdb_api.find(bson command)
```

An insert command, which has an optional document sequence with the identifier “documents” in the form:

```
{'insert': 'coll', 'documents': [{'a':1}, {'a':2}], '$db': 'foo'}
```

Must call a **documentdb_api** function with a single required argument for the command, and an optional argument for the document sequence

```
select documentdb_api.find(bson command, [document_sequence documents])
```

## Detailed Design

### OP_MSG Commands Without A Document Sequence

When the Gateway receives an OP_MSG command, for a command implemented in the extension, with not Section Type 1 fields. The Gateway MUST send the message un-modified to a single **documentdb_api** function in the extension.

### OP_MSG Command With A Document Sequence

When the Gateway receives an OP_MSG command, for a command implemented in the extension, with one or more Section Type 1 fields, the Gateway MUST inspect the identifiers of the Document Sequences, and validate they are appropriate for the command type. Gateway MUST send the message un-modified to a single **documentdb_api** function in the extension the extension API MUST support optional positional argument for accepted document sequences. The Gateway MUST support the Sections in the OP_MSG coming in any order within the command.

The current commands that take document sequences are:

|Command	|Document Sequence Identifiers	|
|---	|---	|
|insert	|documents 	|
|update	|updates	|
|delete	|deletes	|
|bulkWrite	|nsInfo, ops	|

Any document sequence whose identifier does not match what is expected by a command can be ignored.

##### Example

For a bulkWrite which can have two Section Type 1 parts in an OP_MSG the gateway needs to identify which one is the `nsInfo` and which one is the `ops`, and pass them to the extension in a known order.

```
select documentdb_api.bulkWrite(bson command, 
    [document_sequence nsInfo], [document_sequence ops])
```

### Deprecated Message Formats

For any deprecated Mongo Message formats (e.g. OP_QUERY), if the Gateway wishes to provide support for them, it MUST convert the message to match the equivalent command of an OP_MSG, then call the extension as if it was an OP_MSG. This includes adding global command arguments, like $db as needed.

### API Changes

The Gateway currently use 11 APIs the do not match this format (see Appendix), these commands will need to be updated in the Gateway, and potentially have new Extension commands written for them. 

Additionally, [the create index command](https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/processor/indexing.rs#L26) relies on the Gateway making one call to create a background index, and a second to wait for it to complete, this will need to be combined into one command in the Postgres extension.

### Migration Path

Existing APIs are in use by some applications, and cannot be broken with these changes, these updates will need to be implemented by either adding new overrides to the top level functions, or making existing fields optional.

## Appendix

### Glossary

**OP_MSG** 
The modern MongoDB wire protocol message format introduced in MongoDB 3.6. Replaces older formats like OP_QUERY. OP_MSG uses an opcode value of 2013. https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md

**Section Type 0 / Payload Type 0 / Kind 0**
The main command document section in an OP_MSG. Every OP_MSG must contain exactly one Section Type 0, which contains the command name, options, and global arguments like $db. Format: [kind: 0x00] [BSON document] https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md

**Section Type 1 / Payload Type 1 / Kind 1**
Document sequence section in an OP_MSG. Allows bulk array data to be sent without using BSON Arrays, improving efficiency for large batches. Format: [kind: 0x01] [size: int32] [identifier: cstring] [BSON documents...]  https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md

**Document Sequence**
Zero or more BSON documents sent sequentially in a Section Type 1. Each sequence has an identifier (field name) like "documents", "updates", "deletes", "ops", or "nsInfo". Used for bulk operations to avoid BSON Array overhead.

**Global Command Arguments**
Required fields that appear in the main command document (Section Type 0). Examples: $db (required, specifies target database), $readPreference (optional, defaults to primary mode).  https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md

**OP_QUERY**
Legacy MongoDB wire protocol message format (opcode 2004) used before MongoDB 3.6. Deprecated in favor of OP_MSG. https://www.mongodb.com/docs/manual/reference/mongodb-wire-protocol/

|Command	|Document Sequence Identifiers	|	|
|---	|---	|---	|
|insert	|documents 	|[Mongo Spec](https://github.com/mongodb/specifications/blob/master/source/crud/crud.md)	|
|update	|updates	|[Mongo Spec](https://github.com/mongodb/specifications/blob/master/source/crud/crud.md)	|
|delete	|deletes	|[Mongo Spec](https://github.com/mongodb/specifications/blob/master/source/crud/crud.md)	|
|bulkWrite	|nsInfo, ops	|[Mongo Spec](https://github.com/mongodb/specifications/blob/master/source/crud/bulk-write.md)	|

### Current Commands To Be Updated (Based on Gateway Code)

execute_coll_stats: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L102 
execute_drop_collection: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L292
execute_drop_database: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L325
execute_list_databases: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L568 
execute_shard_collection: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L715 
execute_reindex: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L747 
execute_current_op: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L773 
execute_get_parameter: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L850 
execute_db_stats: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L877 
execute_rename_collection: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L902 
execute_kill_cursors: https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/src/postgres/documentdb_data_client.rs#L1137

