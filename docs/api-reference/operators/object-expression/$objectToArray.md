---
title: $objectToArray
description: The objectToArray command is used to transform a document (object) into an array of key-value pairs.
type: operators
category: object-expression
---

# $objectToArray

The `$objectToArray` operator is used to transform a document (object) into an array of key-value pairs. Each key-value pair in the resulting array is represented as a document with `k` and `v` fields. This operator is useful when you need to manipulate or analyze the structure of documents within your collections.

## Syntax

```javascript
{
  $objectToArray: <object>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<object>`** | The document (object) to be transformed into an array of key-value pairs. |

## Examples

Consider this sample document from the stores collection.

```json
{
    "_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4",
    "name": "First Up Consultants | Beverage Shop - Satterfieldmouth",
    "location": {
        "lat": -89.2384,
        "lon": -46.4012
    },
    "staff": {
        "totalStaff": {
            "fullTime": 8,
            "partTime": 20
        }
    },
    "sales": {
        "totalSales": 75670,
        "salesByCategory": [
            {
                "categoryName": "Wine Accessories",
                "totalSales": 34440
            },
            {
                "categoryName": "Bitters",
                "totalSales": 39496
            },
            {
                "categoryName": "Rum",
                "totalSales": 1734
            }
        ]
    },
    "promotionEvents": [
        {
            "eventName": "Unbeatable Bargain Bash",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 6,
                    "Day": 23
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 7,
                    "Day": 2
                }
            },
            "discounts": [
                {
                    "categoryName": "Whiskey",
                    "discountPercentage": 7
                },
                {
                    "categoryName": "Bitters",
                    "discountPercentage": 15
                },
                {
                    "categoryName": "Brandy",
                    "discountPercentage": 8
                },
                {
                    "categoryName": "Sports Drinks",
                    "discountPercentage": 22
                },
                {
                    "categoryName": "Vodka",
                    "discountPercentage": 19
                }
            ]
        },
        {
            "eventName": "Steal of a Deal Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 21
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 9,
                    "Day": 29
                }
            },
            "discounts": [
                {
                    "categoryName": "Organic Wine",
                    "discountPercentage": 19
                },
                {
                    "categoryName": "White Wine",
                    "discountPercentage": 20
                },
                {
                    "categoryName": "Sparkling Wine",
                    "discountPercentage": 19
                },
                {
                    "categoryName": "Whiskey",
                    "discountPercentage": 17
                },
                {
                    "categoryName": "Vodka",
                    "discountPercentage": 23
                }
            ]
        }
    ]
}
```

### Example 1: Transforming the `location` object

This query transforms the `location` object into an array of key-value pairs.

```javascript
db.stores.aggregate([
  {
    $project: {
      locationArray: { $objectToArray: "$location" }
    }
  },
  {
    $limit: 2  // Limit output to first 5 documents
  }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "locationArray": [
      {
        "k": "lat",
        "v": -74.0427
      },
      {
        "k": "lon",
        "v": 160.8154
      }
    ]
  },
  {
    "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
    "locationArray": [
      {
        "k": "lat",
        "v": 61.3945
      },
      {
        "k": "lon",
        "v": -3.6196
      }
    ]
  }
]
```

### Example 2: Transforming the `salesByCategory` array

To transform the `salesByCategory` array, first unwind the array and then apply the `$objectToArray` operator.

```javascript
db.stores.aggregate([
  { $unwind: "$sales.salesByCategory" },
  {
    $project: {
      salesByCategoryArray: { $objectToArray: "$sales.salesByCategory" }
    }
  },
  { 
    $limit: 2
  }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "salesByCategoryArray": [
      {
        "k": "categoryName",
        "v": "Stockings"
      },
      {
        "k": "totalSales",
        "v": 25731
      }
    ]
  },
  {
    "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
    "salesByCategoryArray": [
      {
        "k": "categoryName",
        "v": "Lamps"
      },
      {
        "k": "totalSales",
        "v": 19880
      }
    ]
  }
]
```

Converting subdocuments to key-value pairs is often used when you want to dynamically process field names, especially when:
- Building generic pipelines.
- Mapping field names into key-value structures for flexible transformations or further processing.
