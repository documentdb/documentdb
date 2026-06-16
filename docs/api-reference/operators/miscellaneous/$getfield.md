---
title: $getField
description: The $getField operator allows retrieving the value of a specified field from a document.
type: operators
category: miscellaneous
---

# $getField

The `$getField` operator is used to retrieve the value of a specified field from a document. It's useful when working with dynamic field names or when you need to access fields programmatically within aggregation pipelines.

## Syntax

```javascript
{
  $getField: {
    field: <string>,
    input: <document>
  }
}
```

Or the shorthand syntax:

```javascript
{
  $getField: <string>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | A string representing the name of the field to retrieve. |
| **`input`** | The document from which the field is retrieved. If not specified, defaults to the current document (`$$ROOT`). |

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

### Example 1: Basic field retrieval

Retrieve the total sales value using `$getField`:

```javascript
db.stores.aggregate([
  { $match: {"_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f"} },
  {
    $project: {
      name: 1,
      totalSalesValue: {
        $getField: {
          field: "totalSales",
          input: "$sales"
        }
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
    "name": "First Up Consultants | Bed and Bath Center - South Amir",
    "totalSalesValue": 37701
  }
]
```

### Example 2: Shorthand syntax

Use the shorthand syntax to retrieve the store name:

```javascript
db.stores.aggregate([
  { $match: {"_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f"} },
  {
    $project: {
      storeName: { $getField: "name" },
      storeLocation: { $getField: "location" }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
    "storeName": "First Up Consultants | Bed and Bath Center - South Amir",
    "storeLocation": {
      "lat": 60.7954,
      "lon": -142.0012
    }
  }
]
```
