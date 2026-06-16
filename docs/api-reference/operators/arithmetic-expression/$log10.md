---
title: $log10
description: The $log10 operator calculates the log of a specified number in base 10
type: operators
category: arithmetic-expression
---

# $log10

The `$log10` operator calculates the logarithm of a number in base 10 and returns the result.

## Syntax

```javascript
{
  $log10: <number>
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

### Example 1 - Analyze sales distribution

To bucket the distribution of sales per category within a store, run a query using the $log10 operator on the totalSales field. Then, bucket the categories into "Low", "Medium" and "High" based on the result.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $project: {
            name: 1,
            salesAnalysis: {
                $map: {
                    input: "$sales.salesByCategory",
                    as: "category",
                    in: {
                        categoryName: "$$category.categoryName",
                        originalSales: "$$category.totalSales",
                        logScale: {
                            $log10: "$$category.totalSales"
                        },
                        magnitudeClass: {
                            $switch: {
                                branches: [{
                                        case: {
                                            $lt: [{
                                                $log10: "$$category.totalSales"
                                            }, 3]
                                        },
                                        then: "Low"
                                    },
                                    {
                                        case: {
                                            $lt: [{
                                                $log10: "$$category.totalSales"
                                            }, 4]
                                        },
                                        then: "Medium"
                                    },
                                    {
                                        case: {
                                            $lt: [{
                                                $log10: "$$category.totalSales"
                                            }, 5]
                                        },
                                        then: "High"
                                    }
                                ],
                                default: "Very High"
                            }
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
    "salesAnalysis": [
      {
        "categoryName": "Sound Bars",
        "originalSales": 2120,
        "logScale": 3.326,
        "magnitudeClass": "Medium"
      },
      {
        "categoryName": "Home Theater Projectors",
        "originalSales": 45004,
        "logScale": 4.653,
        "magnitudeClass": "High"
      },
      {
        "categoryName": "Game Controllers",
        "originalSales": 43522,
        "logScale": 4.639,
        "magnitudeClass": "High"
      },
      {
        "categoryName": "Remote Controls",
        "originalSales": 28946,
        "logScale": 4.462,
        "magnitudeClass": "High"
      },
      {
        "categoryName": "VR Games",
        "originalSales": 32272,
        "logScale": 4.509,
        "magnitudeClass": "High"
      }
    ]
  }
]
```
