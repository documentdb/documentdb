---
title: $zip
description: The $zip operator allows merging two or more arrays element-wise into a single array or arrays.
type: operators
category: array-expression
---

# $zip

The `$zip` operator is used to merge two or more arrays element-wise into a single array of arrays. It's useful when you want to combine related elements from multiple arrays into a single array structure.

## Syntax

```javascript
{
  $zip: {
    inputs: [ <array1>, <array2>, ... ],
    useLongestLength: <boolean>, // Optional
    defaults: <array> // Optional
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`inputs`** | An array of arrays to be merged element-wise. |
| **`useLongestLength`** | A boolean value that, if set to true, uses the longest length of the input arrays. If false or not specified, it uses the shortest length. |
| **`defaults`** | An array of default values to use if `useLongestLength` is true and any input array is shorter than the longest array. |

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

### Example 1: Basic Usage

Suppose you want to merge the `categoryName` and `totalSales` fields from the `salesByCategory` array. This query returns individual array of arrays under `categoryWithSales` field. `useLongestLength` set to `true` would return the following output, while a value of `false` removes the `Napkins` array from the output.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6"
        }
    },
    {
        $project: {
            name: 1,
            categoryNames: "$sales.salesByCategory.categoryName",
            totalSales: "$sales.salesByCategory.totalSales",
            categoryWithSales: {
                $zip: {
                    inputs: ["$sales.salesByCategory.categoryName", "$sales.salesByCategory.totalSales"],
                    useLongestLength: false
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
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "categoryNames": ["Stockings"],
    "totalSales": [25731],
    "categoryWithSales": [["Stockings", 25731]]
  }
]
```
