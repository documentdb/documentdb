---
title: $merge
description: The $merge stage in an aggregation pipeline writes the results of the aggregation to a specified collection.
type: operators
category: aggregation
---

# $merge

The `$merge` stage in an aggregation pipeline is used to write the results of the aggregation query into a specified collection. This stage is particularly useful for tasks like updating or inserting documents into a target collection based on the output of an aggregation operation. It helps streamline workflows by combining data transformation and data persistence in a single operation.

## Syntax

```javascript
{
  $merge: {
    into: <collection>,
    on: <field or fields>,
    whenMatched: <action>,
    whenNotMatched: <action>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`into`** | Specifies the target collection where the aggregation results will be written. |
| **`on`** | Specifies the field(s) to identify matching documents in the target collection. |
| **`whenMatched`** | Specifies the action to take when a matching document is found. Options include `merge`, `replace`, `keepExisting`, `fail`, or a custom pipeline. |
| **`whenNotMatched`** | Specifies the action to take when no matching document is found. Options include `insert` or `discard`. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
   "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
  "location": {
    "lat": 60.1441,
    "lon": -141.5012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 2,
      "partTime": 0
    }
  },
  "sales": {
    "salesByCategory": [
      {
        "categoryName": "DJ Headphones",
        "totalSales": 35921
      }
    ],
    "fullSales": 3700
  },
  "promotionEvents": [
    {
      "eventName": "Bargain Blitz Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 3,
          "Day": 11
        },
        "endDate": {
          "Year": 2024,
          "Month": 2,
          "Day": 18
        }
      },
      "discounts": [
        {
          "categoryName": "DJ Turntables",
          "discountPercentage": 18
        },
        {
          "categoryName": "DJ Mixers",
          "discountPercentage": 15
        }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}
```

### Example 1: Merge data into a collection

This query aggregates documents and writes the results to a collection named `salesSummary`, updating existing documents where the `_id` matches and inserting new documents otherwise.

```javascript
db.sales.aggregate([
  {
    $group: {
      _id: "$sales.salesByCategory.categoryName",
      totalSales: { $sum: "$sales.salesByCategory.totalSales" }
    }
  },
  {
    $merge: {
      into: "salesSummary",
      on: "_id",
      whenMatched: "merge",
      whenNotMatched: "insert"
    }
  }
])
```

### Example 2: Replace documents in the target collection

This example replaces documents in the `promotionEventsSummary` collection based on the `_id` field.

```javascript
db.promotionEvents.aggregate([
  {
    $project: {
      _id: "$eventName",
      startDate: "$promotionalDates.startDate",
      endDate: "$promotionalDates.endDate",
      totalDiscounts: { $size: "$discounts" }
    }
  },
  {
    $merge: {
      into: "promotionEventsSummary",
      on: "_id",
      whenMatched: "replace",
      whenNotMatched: "insert"
    }
  }
])
```
