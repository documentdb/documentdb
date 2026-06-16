---
title: $log
description: The $log operator calculates the logarithm of a number in the specified base
type: operators
category: arithmetic-expression
---

# $log

The `$log` operator calculates the logarithm of a number in the specified base.

## Syntax

```javascript
{
  $log: [ <number>, <base> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<number>`** | Any valid expression that resolves to a positive number. |
| **`<base>`** | Any valid expression that resolves to a positive number to be used as the logarithm base. |

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

### Example 1 - Calculate the log of total sales

To calculate the log of sales volumes per category in base 2 and 10, run a query using the $log operator on the totalSales field with bases 2 and 10 respectively to return the desired result.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $project: {
            name: 1,
            categoryAnalysis: {
                $map: {
                    input: "$sales.salesByCategory",
                    as: "category",
                    in: {
                        categoryName: "$$category.categoryName",
                        sales: "$$category.totalSales",
                        logBase2: {
                            $log: ["$$category.totalSales", 2]
                        },
                        logBase10: {
                            $log: ["$$category.totalSales", 10]
                        }
                    }
                }
            }
        }
    }
])
```

This query returns the following result:

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "categoryAnalysis": [
      {
        "categoryName": "Sound Bars",
        "sales": 2120,
        "logBase2": 11.051,
        "logBase10": 3.326
      },
      {
        "categoryName": "Home Theater Projectors",
        "sales": 45004,
        "logBase2": 15.458,
        "logBase10": 4.653
      },
      {
        "categoryName": "Game Controllers",
        "sales": 43522,
        "logBase2": 15.410,
        "logBase10": 4.639
      },
      {
        "categoryName": "Remote Controls",
        "sales": 28946,
        "logBase2": 14.822,
        "logBase10": 4.462
      },
      {
        "categoryName": "VR Games",
        "sales": 32272,
        "logBase2": 14.977,
        "logBase10": 4.509
      }
    ]
  }
]
```
