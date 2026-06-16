---
title: $setEquals
description: The $setEquals operator returns true if two sets have the same distinct elements.
type: operators
category: set-expression
---

# $setEquals

The `$setEquals` operator returns `true` if two sets have the same distinct elements, regardless of order or duplicates. It treats arrays as sets and ignores duplicate values and element order.

## Syntax

```javascript
{
  $setEquals: [ <array1>, <array2>, ... ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `array1, array2, ...` | Arrays to compare for equality. You can specify two or more arrays. |

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

### Example 1: Compare discount categories between events

This query determines if two promotion events offer discounts on the same categories.

```javascript
db.stores.aggregate([
  { $match: {"_id": "26afb024-53c7-4e94-988c-5eede72277d5"} },
  {
    $project: {
      name: 1,
      event1Categories: { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
      event2Categories: { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 1] },
      sameDiscountCategories: {
        $setEquals: [
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 1] }
        ]
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "event1Categories": [
      "Condenser Microphones",
      "Dynamic Microphones"
    ],
    "event2Categories": [
      "Streaming Microphones",
      "Microphone Stands"
    ],
    "sameDiscountCategories": false
  }
]
```

### Example 2: Compare staff requirements

This query determines if two stores have the same staff structure requirements.

```javascript
db.stores.aggregate([
  { $match: {"_id": { $in: ["26afb024-53c7-4e94-988c-5eede72277d5", "f2a8c190-28e4-4e14-9d8b-0256e53dca66"] }} },
  {
    $group: {
      _id: null,
      stores: { $push: { _id: "$_id", name: "$name" }}
    }
  },
  {
    $project: {
      store1: { $arrayElemAt: ["$stores", 0] },
      store2: { $arrayElemAt: ["$stores", 1] },
      staffTypes1: ["fullTime", "partTime"],
      staffTypes2: ["fullTime", "partTime"],
      sameStaffStructure: {
        $setEquals: [
          ["fullTime", "partTime"],
          ["fullTime", "partTime"]
        ]
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": null,
    "store1": {
      "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
      "name": "First Up Consultants | Microphone Bazaar - South Lexusland"
    },
    "store2": {
      "_id": "f2a8c190-28e4-4e14-9d8b-0256e53dca66",
      "name": "Fabrikam, Inc. | Car Accessory Outlet - West Adele"
    },
    "staffTypes1": ["fullTime", "partTime"],
    "staffTypes2": ["fullTime", "partTime"],
    "sameStaffStructure": true
  }
]
```

### Example 3: Compare sets with duplicates

This query uses the `$setEquals` operator to ignore duplicates and order.

```javascript
db.stores.aggregate([
  { $match: {"_id": "26afb024-53c7-4e94-988c-5eede72277d5"} },
  {
    $project: {
      name: 1,
      array1: ["Microphones", "Stands", "Microphones", "Accessories"],
      array2: ["Stands", "Accessories", "Microphones"],
      arraysEqual: {
        $setEquals: [
          ["Microphones", "Stands", "Microphones", "Accessories"],
          ["Stands", "Accessories", "Microphones"]
        ]
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "array1": ["Microphones", "Stands", "Microphones", "Accessories"],
    "array2": ["Stands", "Accessories", "Microphones"],
    "arraysEqual": true
  }
]
```
