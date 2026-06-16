---
title: $bitOr
description: The $bitOr operator performs a bitwise OR operation on integer values and returns the result as an integer.
type: operators
category: bitwise
---

# $bitOr

The `$bitOr` operator performs a bitwise OR operation on integer values. It compares each bit of the first operand to the corresponding bit of the second operand. If either bit is 1, the corresponding result bit is set to 1. If both bits are 0, the corresponding result bit is set to 0.

## Syntax

```javascript
{
  $bitOr: [ <expression1>, <expression2>, ... ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression1, expression2, ...`** | Expressions that evaluate to integers. The `$bitOr` operator performs a bitwise OR operation on all provided expressions. |

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

### Example 1: Basic bitwise OR operation

This query performs a bitwise OR operation on the staff values of a specific store document to combine permission flags. The bitwise OR of 3 (011 in binary) and 2 (010 in binary) equals 3 (011 in binary).

```javascript
db.stores.aggregate([{
        $match: {
            _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66"
        }
    },
    {
        $project: {
            name: 1,
            fullTimeStaff: "$staff.totalStaff.fullTime",
            partTimeStaff: "$staff.totalStaff.partTime",
            combinedStaffFlag: {
                $bitOr: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
            }
        }
    }
])
```

This query returns the following result.

```json
[
  {
    "_id": "f2a8c190-28e4-4e14-9d8b-0256e53dca66",
    "name": "Fabrikam, Inc. | Car Accessory Outlet - West Adele",
    "fullTimeStaff": 3,
    "partTimeStaff": 2,
    "combinedStaffFlag": 3
  }
]
```

### Example 2: Multiple value bitwise OR with discount percentages

This query extracts discount details for a specific promotion event and computes a bitwise flag combining discounts and staff values. The output shows the results of the aggregation query that calculates a combined bitwise flag for each discount in the event `Super Saver Spectacular`. The operation combines discount percentages with staff numbers using bitwise OR: 7|3|2 = 7 and 11|3|2 = 11.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "f2a8c190-28e4-4e14-9d8b-0256e53dca66"
        }
    },
    {
        $unwind: "$promotionEvents"
    },
    {
        $match: {
            "promotionEvents.eventName": "Super Saver Spectacular"
        }
    },
    {
        $project: {
            name: 1,
            eventName: "$promotionEvents.eventName",
            discountFlags: {
                $map: {
                    input: "$promotionEvents.discounts",
                    as: "discount",
                    in: {
                        categoryName: "$$discount.categoryName",
                        discountPercentage: "$$discount.discountPercentage",
                        combinedFlag: {
                            $bitOr: [
                                "$$discount.discountPercentage",
                                "$staff.totalStaff.fullTime",
                                "$staff.totalStaff.partTime"
                            ]
                        }
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
    "_id": "f2a8c190-28e4-4e14-9d8b-0256e53dca66",
    "name": "Fabrikam, Inc. | Car Accessory Outlet - West Adele",
    "eventName": "Super Saver Spectacular",
    "discountFlags": [
      {
        "categoryName": "Car Chargers",
        "discountPercentage": 7,
        "combinedFlag": 7
      },
      {
        "categoryName": "Dash Cameras",
        "discountPercentage": 11,
        "combinedFlag": 11
      }
    ]
  }
]
```
