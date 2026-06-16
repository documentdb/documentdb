---
title: $fill
description: The $fill stage allows filling missing values in documents based on specified methods and criteria.
type: operators
category: aggregation
---

# $fill

The `$fill` stage is used to fill missing or null values in documents within the aggregation pipeline. It provides various methods to populate missing data, including using static values, linear interpolation, or values from previous/next documents.

## Syntax

```javascript
{
  $fill: {
    sortBy: <sort specification>,
    partitionBy: <partition fields>,
    partitionByFields: <array of partition field names>,
    output: {
      <field1>: { value: <expression> },
      <field2>: { method: <string> }
    }
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`sortBy`** | Specifies the sort order for documents when applying fill methods that depend on document order. |
| **`partitionBy`** | Optional. Groups documents into partitions. Fill operations are applied within each partition separately. |
| **`partitionByFields`** | Optional. Alternative syntax for partitionBy using an array of field names. |
| **`output`** | Specifies the fields to fill and the method or value to use for filling missing data. |

### Fill Methods

| Method | Description |
| --- | --- |
| **`value`** | Fill with a specified static value or expression result. |
| **`linear`** | Fill using linear interpolation between known values (numeric fields only). |
| **`locf`** | Last Observation Carried Forward - use the last known value. |
| **`linear`** | Linear interpolation between surrounding values. |

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

### Example 1: Fill missing values with static value

This query fills missing `totalSales` values in the `salesByCategory` array with a default value of 0.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $unwind: "$sales.salesByCategory"
}, {
    $fill: {
        output: {
            "sales.salesByCategory.totalSales": {
                value: 0
            }
        }
    }
}, {
    $group: {
        _id: "$_id",
        name: {
            $first: "$name"
        },
        salesByCategory: {
            $push: "$sales.salesByCategory"
        }
    }
}])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "affdc09c-7356-4fff-a857-e8301f57159c",
        "name": "First Up Consultants | Sports Gear Pantry - Wildermanhaven",
        "salesByCategory": [
            {
                "categoryName": "Baseball Gear",
                "totalSales": 33878
            },
            {
                "categoryName": "Volleyball Gear",
                "totalSales": 34031
            }
        ]
    },
    {
        "_id": "1cf667b4-d8ce-4f1a-bad1-a1f0bbce26c2",
        "name": "First Up Consultants | Picture Frame Variety - New Abrahamborough",
        "salesByCategory": [
            {
                "categoryName": "Picture Hanging Supplies",
                "totalSales": 7229
            },
            {
                "categoryName": "Collage Frames",
                "totalSales": 40014
            }
        ]
    }
]
```

### Example 2: Fill missing staff data using last observation carried forward

This query fills missing part-time staff data using the last known value within each store group.

```javascript
db.stores.aggregate([{
    $fill: {
        sortBy: {
            "_id": 1
        },
        output: {
            "staff.totalStaff.partTime": {
                method: "locf"
            }
        }
    }
}, {
    $project: {
        name: 1,
        "staff.totalStaff": 1
    }
}])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "00003278-4226-4ca7-871d-e80d8f414431",
        "name": "Wide World Importers | Camera Depot - Lake Luramouth",
        "staff": {
            "totalStaff": {
                "fullTime": 20,
                "partTime": 6
            }
        }
    },
    {
        "_id": "00009bd0-c44e-4cc8-ab03-347076d74a1a",
        "name": "Wide World Importers | Music Stop - Rebeccaside",
        "staff": {
            "totalStaff": {
                "fullTime": 9,
                "partTime": 0
            }
        }
    }
]
```

### Example 3: Fill missing discount percentages with average value

This query fills missing discount percentages with the average discount percentage across all stores.

```javascript
db.stores.aggregate([
  { $unwind: "$promotionEvents" },
  { $unwind: "$promotionEvents.discounts" },
  {
    $fill: {
      partitionBy: "$promotionEvents.eventName",
      sortBy: { "promotionEvents.discounts.categoryName": 1 },
      output: {
        "promotionEvents.discounts.discountPercentage": { 
          value: { $avg: "$promotionEvents.discounts.discountPercentage" } 
        }
      }
    }
  },
  {
    $group: {
      _id: { storeId: "$_id", eventName: "$promotionEvents.eventName" },
      storeName: { $first: "$name" },
      eventName: { $first: "$promotionEvents.eventName" },
      discounts: { $push: "$promotionEvents.discounts" }
    }
  }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": {
            "storeId": "70d4cc90-23b1-46e3-8f59-630648e311a4",
            "eventName": "Price Slash Spectacular"
        },
        "storeName": "Wide World Importers | Music Bazaar - West Johnpaulhaven",
        "eventName": "Price Slash Spectacular",
        "discounts": [
            {
                "categoryName": "CDs",
                "discountPercentage": 22
            },
            {
                "categoryName": "Vinyl Records",
                "discountPercentage": 21
            }
        ]
    },
    {
        "_id": {
            "storeId": "24873ac4-b2d1-4216-a425-3375a384b23d",
            "eventName": "Massive Deal Mania"
        },
        "storeName": "Northwind Traders | Furniture Pantry - Farrellchester",
        "eventName": "Massive Deal Mania",
        "discounts": [
            {
                "categoryName": "Bookcases",
                "discountPercentage": 22
            },
            {
                "categoryName": "Cabinets",
                "discountPercentage": 8
            }
        ]
    }
]
```

## Use Cases

- **Data Cleaning**: Fill missing values in imported datasets
- **Time Series Data**: Handle gaps in sequential data using interpolation
- **Default Values**: Assign default values to optional fields
- **Data Normalization**: Ensure consistent data structure across documents
