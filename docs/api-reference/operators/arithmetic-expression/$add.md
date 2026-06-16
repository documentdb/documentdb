---
title: $add
description: The $add operator returns the sum of two numbers or the sum of a date and numbers.
type: operators
category: arithmetic-expression
---

# $add

The `$add` operator adds numbers together or adds numbers and dates. When adding numbers and dates, the numbers are interpreted as milliseconds.

## Syntax

```javascript
{
  $add: [ <listOfExpressions> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<listOfExpressions>`** | Any valid expressions that resolve to numbers or dates. The expressions can be any combination of numbers and dates. |

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

### Example 1 - Get the current and project staff count

To calculate the total staff and project the total staff looking forward, use the $add operator on the nested totalStaff object to return the desired results.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
    }
}, {
    $project: {
        name: 1,
        currentTotalStaff: {
            $add: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
        },
        projectedNextYearStaff: {
            $add: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime", 2]
        }
    }
}])
```

This query returns the following result:

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "currentTotalStaff": 39,
    "projectedNextYearStaff": 41
  }
]
```
