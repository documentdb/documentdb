---
title: $allElementsTrue
description: The $allElementsTrue operator returns true if all elements in an array evaluate to true.
type: operators
category: set-expression
---

# $allElementsTrue

The `$allElementsTrue` operator evaluates an array as a set. It returns `true` if no element in the array has a value of `false` or equivalent to `false` (like `null`, `0`, or `undefined`). If any element evaluates to a value of `false` or the equivalent, the operator returns `false`.

## Syntax

```javascript
{
  $allElementsTrue: [ <array> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `array` | An array of expressions to evaluate. If the array is empty, `$allElementsTrue` returns `true`. |

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

### Example 1: Determine if all the discount percentages are higher than zero

This query determines if all the discount percentages in each promotion event are greater than zero.

```javascript
db.stores.aggregate([
  { $match: {"_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f"} },
  { $unwind: "$promotionEvents" },
  {
    $project: {
      allDiscountsValid: {
        $allElementsTrue: [
          {
            $map: {
              input: "$promotionEvents.discounts.discountPercentage",
              as: "discount",
              in: { $gt: ["$$discount", 0] }
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
    "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
    "allDiscountsValid": true
  }
]
```
