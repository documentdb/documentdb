---
title: $anyElementTrue
description: The $anyElementTrue operator returns true if any element in an array evaluates to a value of true.
type: operators
category: set-expression
---

# $anyElementTrue

The `$anyElementTrue` operator evaluates an array as a set and returns `true` if any element in the array is `true` (or equivalent to `true`). If all the elements evaluate to a value of `false`, `null`, `0`, or `undefined`, the operator returns `false`.

## Syntax

```javascript
{
  $anyElementTrue: [ <array> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `array` | An array of expressions to evaluate. If the array is empty, `$anyElementTrue` returns `false`. |

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

### Example 1: Determine if any sales category exceeds a target

This query determines if any sales category exceeds a specified target. In this case, the target is 40,000 in sales.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      salesByCategory: "$sales.salesByCategory",
      hasHighPerformingCategory: {
        $anyElementTrue: [
          {
            $map: {
              input: "$sales.salesByCategory",
              as: "category",
              in: { $gt: ["$$category.totalSales", 40000] }
            }
          }
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
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2120,
        "lastUpdated": "2025-06-11T11:10:34.414Z"
      },
      null,
      {
        "categoryName": "Game Controllers",
        "totalSales": 43522
      },
      {
        "categoryName": "Remote Controls",
        "totalSales": 28946
      },
      {
        "categoryName": "VR Games",
        "totalSales": 32272
      }
    ],
    "hasHighPerformingCategory": true
  }
]
```

### Example 2: Determine if any promotion event has high discounts

This query determines if any promotion event offers discounts over 20%.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  { $unwind: "$promotionEvents" },
  {
    $project: {
      eventName: "$promotionEvents.eventName",
      hasHighDiscount: {
        $anyElementTrue: [
          {
            $map: {
              input: "$promotionEvents.discounts",
              as: "discount",
              in: { $gte: ["$$discount.discountPercentage", 20] }
            }
          }
        ]
      }
    }
  }
])
```

The first five results returned by this query are:

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Massive Markdown Mania",
    "hasHighDiscount": true
  },
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Fantastic Deal Days",
    "hasHighDiscount": true
  },
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Discount Delight Days",
    "hasHighDiscount": true
  },
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Super Sale Spectacular",
    "hasHighDiscount": true
  },
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Grand Deal Days",
    "hasHighDiscount": true
  }
]
```
