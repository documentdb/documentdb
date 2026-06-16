---
title: $bucketAuto
description: The $bucketAuto stage automatically distributes documents into a specified number of buckets based on a grouping expression.
type: operators
category: aggregation
---

# $bucketAuto

The `$bucketAuto` stage categorizes documents into a specified number of buckets, attempting to evenly distribute the documents based on the values of a `groupBy` expression. Unlike [`$bucket`](./%24bucket.md), you do not have to provide boundaries — DocumentDB computes them for you.

Supported since `v0.105-0`.

## Syntax

```javascript
{
  $bucketAuto: {
    groupBy: <expression>,
    buckets: <number>,
    output: {
      <outputField1>: { <accumulator1> },
      ...
    },
    granularity: <granularity-string>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`groupBy`** | An expression to group documents by. The expression must resolve to a value that can be compared. |
| **`buckets`** | A positive 32-bit integer that specifies the number of buckets into which the input documents should be grouped. |
| **`output`** | Optional. A document that specifies the fields to compute for each bucket. Each field is an accumulator expression such as `$sum`, `$avg`, `$min`, `$max`, `$push`, or `$addToSet`. If omitted, `$bucketAuto` outputs a `count` field by default. |
| **`granularity`** | Optional. A string that specifies the [preferred number series](https://en.wikipedia.org/wiki/Preferred_number) used to round the bucket boundaries. Supported values: `POWERSOF2`, `1-2-5`, `R5`, `R10`, `R20`, `R40`, `R80`, `E6`, `E12`, `E24`, `E48`, `E96`, `E192`. The `groupBy` values must be numeric and non-negative when `granularity` is used. |

## Behavior

- `$bucketAuto` outputs documents with an `_id` of the form `{ "min": <lower>, "max": <upper> }`, representing the bucket's lower and upper boundary. The upper boundary is exclusive for all buckets except the last, which includes its upper boundary.
- When the number of distinct `groupBy` values is less than `buckets`, the stage produces fewer buckets than requested.
- When `granularity` is specified, the computed boundaries are rounded outward to the nearest preferred number.

## Examples

Consider this sample `sales` collection:

```json
[
  { "_id": 1, "category": "Books",       "price":   8 },
  { "_id": 2, "category": "Books",       "price":  12 },
  { "_id": 3, "category": "Electronics", "price":  45 },
  { "_id": 4, "category": "Electronics", "price": 230 },
  { "_id": 5, "category": "Toys",        "price":   3 },
  { "_id": 6, "category": "Toys",        "price":  18 },
  { "_id": 7, "category": "Clothing",    "price":  35 },
  { "_id": 8, "category": "Clothing",    "price":  60 }
]
```

### Example 1: Three even price buckets

Group the sales into three buckets that contain roughly the same number of documents, and compute a count and average price per bucket:

```javascript
db.sales.aggregate([
  {
    $bucketAuto: {
      groupBy: "$price",
      buckets: 3,
      output: {
        count: { $sum: 1 },
        avgPrice: { $avg: "$price" }
      }
    }
  }
])
```

Sample output:

```json
[
  { "_id": { "min": 3,  "max": 18  }, "count": 3, "avgPrice": 9.67 },
  { "_id": { "min": 18, "max": 45  }, "count": 3, "avgPrice": 28.33 },
  { "_id": { "min": 45, "max": 230 }, "count": 2, "avgPrice": 145 }
]
```

### Example 2: Buckets with rounded boundaries via `granularity`

Group prices into four buckets rounded to a power-of-two series:

```javascript
db.sales.aggregate([
  {
    $bucketAuto: {
      groupBy: "$price",
      buckets: 4,
      granularity: "POWERSOF2"
    }
  }
])
```

Sample output:

```json
[
  { "_id": { "min": 2,   "max": 16  }, "count": 3 },
  { "_id": { "min": 16,  "max": 32  }, "count": 1 },
  { "_id": { "min": 32,  "max": 64  }, "count": 2 },
  { "_id": { "min": 64,  "max": 256 }, "count": 2 }
]
```

## See Also

- [`$bucket`](./%24bucket.md) — fixed-boundary bucketing.
- [`$group`](./%24group.md) — generic grouping by an expression.
