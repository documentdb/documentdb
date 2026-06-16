---
title: $abs
description: The $abs operator returns the absolute value of a number.
type: operators
category: arithmetic-expression
---

# $abs

The `$abs` operator returns the absolute value of a number. It removes any negative sign from a number, making it positive.

## Syntax

```javascript
{
  $abs: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression>`** | Any expression that resolves to a number. If the expression is null or refers to a missing field, $abs returns null. |

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

### Example 1 - Use the absolute value of total sales

To calculate the absolute difference in sales volume of each category and the average sales across all categories for a store, first run a query to filter on the specific store. Then, calculate the difference in sales between each category and the average across all categories. Lastly, project the absolute difference using the $abs operator.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
    }
}, {
    $project: {
        name: 1,
        salesByCategory: {
            $map: {
                input: "$sales.salesByCategory",
                as: "category",
                in: {
                    categoryName: "$$category.categoryName",
                    totalSales: "$$category.totalSales",
                    differenceFromAverage: {
                        $abs: {
                            $subtract: ["$$category.totalSales", {
                                $avg: "$sales.salesByCategory.totalSales"
                            }]
                        }
                    }
                }
            }
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
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2120,
        "differenceFromAverage": 28252.8
      },
      {
        "categoryName": "Home Theater Projectors",
        "totalSales": 45004,
        "differenceFromAverage": 14631.2
      },
      {
        "categoryName": "Game Controllers",
        "totalSales": 43522,
        "differenceFromAverage": 13149.2
      },
      {
        "categoryName": "Remote Controls",
        "totalSales": 28946,
        "differenceFromAverage": 1426.8
      },
      {
        "categoryName": "VR Games",
        "totalSales": 32272,
        "differenceFromAverage": 1899.2
      }
    ]
  }
]
```
