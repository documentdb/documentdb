---
title: $addFields
description: The $addFields stage in the aggregation pipeline is used to add new fields to documents.
type: operators
category: aggregation
---

# $addFields

The $addFields stage in the aggregation pipeline is used to add new fields to documents. It can also be used to reset the values of existing fields. This stage is particularly useful when you need to create new fields based on existing data or modify existing fields within your documents.

## Syntax

```javascript
{
  $addFields: {
    <newField1>: <expression1>,
    <newField2>: <expression2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`newField1`** | The name of the new field to add or the existing field to modify. |
| **`expression1`** | The expression to compute the value of newField1. |

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

### Example 1: Adding a new field

This query adds a new field totalDiscountEvents that counts the number of promotion events

```javascript
db.stores.aggregate([
  {
    $addFields: {
      totalDiscountEvents: { $size: "$store.promotionEvents" }
    }
  }
])
```

This query returns the following result:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": ["Summer Sale", "Black Friday", "Holiday Deals"]
    },
    "totalDiscountEvents": 3
  }
]
```

### Example 2: Modifying an Existing Field

This query adds a field totalStaffCount that sums up the full-time and part-time staff.

```javascript
db.stores.aggregate([
  {
    $addFields: {
      totalStaffCount: {
        $add: ["$store.staff.totalStaff.fullTime", "$store.staff.totalStaff.partTime"]
      }
    }
  }
])
```

This query returns the following result:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "staff": {
        "totalStaff": {
          "fullTime": 12,
          "partTime": 8
        }
      }
    },
    "totalStaffCount": 20
  }
]
```

### Example 3: Adding Nested Fields

This query adds a nested field location.coordinates that combines latitude and longitude into an array.

```javascript
db.stores.aggregate([
  {
    $addFields: {
      "store.location.coordinates": ["$store.location.lat", "$store.location.lon"]
    }
  }
])
```

This query returns the following result:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "location": {
        "lat": 47.6097,
        "lon": -122.3331,
        "coordinates": [47.6097, -122.3331]
      }
    }
  }
]
```
