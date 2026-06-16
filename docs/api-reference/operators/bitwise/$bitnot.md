---
title: $bitNot
description: The $bitNot operator performs a bitwise NOT operation on integer values and returns the result as an integer.
type: operators
category: bitwise
---

# $bitNot

The `$bitNot` operator performs a bitwise NOT operation on integer values. It inverts all the bits of the operand, turning 1s into 0s and 0s into 1s. The result is the bitwise complement of the input value.

## Syntax

```javascript
{
  $bitNot: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | An expression that evaluates to an integer. The `$bitNot` operator performs a bitwise NOT operation on this value. |

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

### Example 1: Basic bitwise NOT operation

This query performs a bitwise inversion on the staff count fields for a specific store document. The inverted values can be used for special permission flags, feature toggles, or bitmask operations. The bitwise NOT of 14 results are -15, and the bitwise NOT of 8 results in -9. The observed result is due to two's complement representation where ~n = -(n+1).

```javascript
db.stores.aggregate([{
        $match: {
            _id: "26afb024-53c7-4e94-988c-5eede72277d5"
        }
    },
    {
        $project: {
            name: 1,
            fullTimeStaff: "$staff.totalStaff.fullTime",
            partTimeStaff: "$staff.totalStaff.partTime",
            invertedFullTime: {
                $bitNot: "$staff.totalStaff.fullTime"
            },
            invertedPartTime: {
                $bitNot: "$staff.totalStaff.partTime"
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
    "fullTimeStaff": 14,
    "partTimeStaff": 8,
    "invertedFullTime": -15,
    "invertedPartTime": -9
  }
]
```

### Example 2: Using $bitNot with discount percentages

This query extracts and processes discount information for a specific store and applies a bitwise NOT operation on each discount percentage. The bitwise NOT operation inverts all bits: 20 becomes -21 and 17 becomes -18.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "26afb024-53c7-4e94-988c-5eede72277d5"
        }
    },
    {
        $unwind: "$promotionEvents"
    },
    {
        $match: {
            "promotionEvents.eventName": "Incredible Savings Showcase"
        }
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    {
        $project: {
            name: 1,
            eventName: "$promotionEvents.eventName",
            categoryName: "$promotionEvents.discounts.categoryName",
            discountPercentage: "$promotionEvents.discounts.discountPercentage",
            invertedDiscount: {
                $bitNot: "$promotionEvents.discounts.discountPercentage"
            }
        }
    }
])
```

This query returns the following results:

```json
[
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "eventName": "Incredible Savings Showcase",
    "categoryName": "Microphone Stands",
    "discountPercentage": 17,
    "invertedDiscount": -18
  },
  {
    "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
    "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
    "eventName": "Incredible Savings Showcase",
    "categoryName": "Condenser Microphones",
    "discountPercentage": 20,
    "invertedDiscount": -21
  }
]
```
