---
title: getMore
description: The getMore command is used to retrieve extra batches of documents from an existing cursor.
type: commands
category: query-and-write
---

# getMore

The `getMore` command is used to retrieve extra batches of documents from an existing cursor. This command is useful when dealing with large datasets that can't be fetched in a single query due to size limitations. The command allows clients to paginate through the results in manageable chunks with commands that return a cursor. For example, [find](./find) and [aggregate](../aggregation/aggregate), to return subsequent batches of documents currently pointed to by the cursor.

## Syntax

The syntax for the `getMore` command is as follows:

```javascript
{
   getMore: <cursor-id>,
   collection: <collection-name>,
   batchSize: <number-of-documents>
}
```

- `getMore`: The unique identifier for the cursor from which to retrieve more documents.
- `collection`: The name of the collection associated with the cursor.
- `batchSize`: (Optional) The number of documents to return in the batch. If not specified, the server uses the default batch size.

## Examples

### Example 1: Retrieve more documents from a cursor

Assume you have a cursor with the ID `1234567890` from the `stores` collection. The following command retrieves the next batch of documents:

```javascript
{
   getMore: 1234567890,
   collection: "stores",
   batchSize: 5
}
```

### Example 2: Retrieve more documents without specifying batch size

If you don't specify the `batchSize`, the server uses the default batch size:

```javascript
{
   getMore: 1234567890,
   collection: "stores"
}
```
