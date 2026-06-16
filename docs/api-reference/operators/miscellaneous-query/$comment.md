---
title: $comment
description: The $comment operator adds a comment to a query to help identify the query in logs and profiler output.
type: operators
category: miscellaneous-query
---

# $comment

The `$comment` operator adds comments to queries to help identify them in logs and profiler output. This is particularly useful for debugging and monitoring database operations.

## Syntax

```javascript
{
  $comment: <string>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`string`** | A string containing the comment to be included with the query. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
  "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
  "location": {
    "lat": 70.1272,
    "lon": 69.7296
  },
  "staff": {
    "totalStaff": {
      "fullTime": 19,
      "partTime": 20
    }
  },
  "sales": {
    "totalSales": 151864,
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2120
      },
      {
        "categoryName": "Home Theater Projectors",
        "totalSales": 45004
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Massive Markdown Mania",
      "promotionalDates": {
        "startDate": {
          "Year": 2023,
          "Month": 6,
          "Day": 29
        },
        "endDate": {
          "Year": 2023,
          "Month": 7,
          "Day": 9
        }
      },
      "discounts": [
        {
          "categoryName": "DVD Players",
          "discountPercentage": 14
        }
      ]
    }
  ]
}
```

### Example 1: Find stores with total sales over 100,000 and add a log comment for reference

This query retrieves stores with total sales greater than 100,000 and includes a comment for easy identification in logs.

```javascript
db.stores.find(
   { "sales.totalSales": { $gt: 100000 } },
   { name: 1, "sales.totalSales": 1 }
).comment("Query to find high-performing stores")
```

This query returns the following result.

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "sales": {
      "totalSales": 151864
    }
  }
]
```
