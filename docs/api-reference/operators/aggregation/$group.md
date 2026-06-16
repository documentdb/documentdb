---
title: $group
description: The $group stage groups documents by specified identifier expressions and applies accumulator expressions.
type: operators
category: aggregation
---

# $group

The `$group` aggregation stage groups documents by specified identifier expressions and applies accumulator expressions to create computed fields for each group. This stage is essential for data aggregation and summarization operations.

## Syntax

```javascript
{
  $group: {
    _id: <expression>,
    <field1>: { <accumulator1>: <expression1> },
    <field2>: { <accumulator2>: <expression2> }
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`_id`** | Required. The expression to group by. Use null to calculate accumulated values for all input documents. |
| **`field`** | Optional. Computed using accumulator operators like $sum, $avg, $max, $min, $count, etc. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
  "name": "First Up Consultants | Bed and Bath Center - South Amir",
  "location": {
    "lat": 60.7954,
    "lon": -142.0012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 18,
      "partTime": 17
    }
  },
  "sales": {
    "totalSales": 37701,
    "salesByCategory": [
      {
        "categoryName": "Mattress Toppers",
        "totalSales": 37701
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Price Drop Palooza",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 21
        },
        "endDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 30
        }
      },
      "discounts": [
        {
          "categoryName": "Bath Accessories",
          "discountPercentage": 18
        },
        {
          "categoryName": "Pillow Top Mattresses",
          "discountPercentage": 17
        }
      ]
    }
  ]
}
```

### Example 1: Group staffing analysis by city

This query groups stores by city and analyzes the staffing patterns across different locations.

```javascript
db.stores.aggregate([
  {
    $group: {
      _id: "$city",
      totalFullTimeStaff: { $sum: "$staff.employeeCount.fullTime" },
      totalPartTimeStaff: { $sum: "$staff.employeeCount.partTime" },
      avgFullTimeStaff: { $avg: "$staff.employeeCount.fullTime" },
      storesInCity: { $count: {} }
    }
  },
  {
    $project: {
      city: "$_id",
      totalFullTimeStaff: 1,
      totalPartTimeStaff: 1,
      avgFullTimeStaff: { $round: ["$avgFullTimeStaff", 1] },
      storesInCity: 1,
      fullTimeRatio: {
        $round: [
          { $divide: ["$totalFullTimeStaff", { $add: ["$totalFullTimeStaff", "$totalPartTimeStaff"] }] },
          2
        ]
      }
    }
  },
  { $limit : 2}
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "New Ellsworth",
    "totalFullTimeStaff": 11,
    "totalPartTimeStaff": 1,
    "avgFullTimeStaff": 11,
    "storesInCity": 1,
    "city": "New Ellsworth",
    "fullTimeRatio": 0.92
  },
  {
    "_id": "Jalonborough",
    "totalFullTimeStaff": 4,
    "totalPartTimeStaff": 1,
    "avgFullTimeStaff": 4,
    "storesInCity": 1,
    "city": "Jalonborough",
    "fullTimeRatio": 0.8
  }
]
```
