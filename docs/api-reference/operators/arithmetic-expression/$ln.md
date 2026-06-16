---
title: $ln
description: The $ln operator calculates the natural logarithm of the input
type: operators
category: arithmetic-expression
---

# $ln

The `$ln` operator calculates the natural logarithm (base e) of the input number.

## Syntax

```javascript
{
  $ln: <number>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<number>`** | Any valid expression that resolves to a positive number. |

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

### Example 1 - Calculate the natural logarithm of total sales by category

To calculate the natural logarithm of sales volume by category to analyze growth rates, run a query using the $ln operator on the totalSales field to return the desired result.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $project: {
            name: 1,
            salesGrowthMetrics: {
                $map: {
                    input: "$sales.salesByCategory",
                    as: "category",
                    in: {
                        categoryName: "$$category.categoryName",
                        salesValue: "$$category.totalSales",
                        naturalLog: {
                            $ln: "$$category.totalSales"
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
    "salesGrowthMetrics": [
      {
        "categoryName": "Sound Bars",
        "salesValue": 2120,
        "naturalLog": 7.659
      },
      {
        "categoryName": "Home Theater Projectors",
        "salesValue": 45004,
        "naturalLog": 10.714
      },
      {
        "categoryName": "Game Controllers",
        "salesValue": 43522,
        "naturalLog": 10.681
      },
      {
        "categoryName": "Remote Controls",
        "salesValue": 28946,
        "naturalLog": 10.273
      },
      {
        "categoryName": "VR Games",
        "salesValue": 32272,
        "naturalLog": 10.382
      }
    ]
  }
]
```
