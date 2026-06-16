---
title: $reduce
description: The $reduce operator applies an expression to each element in an array & accumulate result as single value.
type: operators
category: array-expression
---

# $reduce

The `$reduce` operator is used to apply an expression to each element in an array and accumulate the results into a single value. This operator is useful for performing operations that require iterating over array elements and aggregating their values.

## Syntax

```javascript
$reduce: {
   input: <array>,
   initialValue: <expression>,
   in: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The array to iterate over. |
| **`initialValue`** | The initial cumulative value set before the array iteration begins. |
| **`in`** | A valid expression that evaluates to the accumulated value for each element in the array. |

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

### Example 1: Aggregates the array values

This query demonstrates how to use `$reduce` to sum the total sales across different categories in the `salesByCategory` array.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "988d2dd1-2faa-4072-b420-b91b95cbfd60"
    }
}, {
    $project: {
        totalSalesByCategory: {
            $reduce: {
                input: "$sales.salesByCategory.totalSales",
                initialValue: 0,
                in: {
                    $add: ["$$value", "$$this"]
                }
            }
        }
    }
}])
```

The query returns the following result.

```json
[
  {
      "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
      "totalSalesByCategory": 149849
  }
]
```
