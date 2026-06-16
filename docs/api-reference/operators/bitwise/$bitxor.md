---
title: $bitXor
description: The $bitXor operator performs a bitwise XOR operation on integer values.
type: operators
category: bitwise
---

# $bitXor

The `$bitXor` operator performs a bitwise exclusive OR (XOR) operation on integer values. The XOR operation returns 1 for each bit position where the corresponding bits of the operands are different, and 0 where they're the same.

## Syntax

```javascript
{
  $bitXor: [ <expression1>, <expression2>, ... ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression1, expression2, ...`** | Expressions that resolve to integer values. The operator performs XOR operations on these values in sequence. |

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

### Example 1: Basic XOR operation

This query uses an aggregation pipeline to calculate between full-time and part-time staff counts for a specific store. The resulting document contains the store details along with a computed field. The XOR operation between 19 (binary: 10011) and 20 (binary: 10100) results in 7 (binary: 00111).

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $project: {
            name: 1,
            fullTimeStaff: "$staff.totalStaff.fullTime",
            partTimeStaff: "$staff.totalStaff.partTime",
            staffXor: {
                $bitXor: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
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
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "fullTimeStaff": 19,
    "partTimeStaff": 20,
    "staffXor": 7
  }
]
```

### Example 2: XOR with Multiple Values

This query computes the bitwise XOR of all discount percentages for the `Discount Delight Days` event of a specific store. The resulting document represents the bitwise XOR calculation of all discount percentages for the `Discount Delight Days` event.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $unwind: "$promotionEvents"
    },
    {
        $match: {
            "promotionEvents.eventName": "Discount Delight Days"
        }
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    {
        $group: {
            _id: "$_id",
            name: {
                $first: "$name"
            },
            eventName: {
                $first: "$promotionEvents.eventName"
            },
            discountPercentages: {
                $push: "$promotionEvents.discounts.discountPercentage"
            }
        }
    },
    {
        $project: {
            name: 1,
            eventName: 1,
            discountPercentages: 1,
            xorResult: {
                $reduce: {
                    input: {
                        $map: {
                            input: "$discountPercentages",
                            as: "val",
                            in: {
                                $toLong: "$$val"
                            }
                        }
                    },
                    initialValue: {
                        $toLong: 0
                    },
                    in: {
                        $bitXor: ["$$value", "$$this"]
                    }
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
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "eventName": "Discount Delight Days",
    "discountPercentages": [22, 23, 10, 10, 9, 24],
    "xorResult": { "$numberLong": "16" }
  }
]
```
