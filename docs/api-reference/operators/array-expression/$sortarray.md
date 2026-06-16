---
title: $sortArray
description: The $sortArray operator helps in sorting the elements in an array.
type: operators
category: array-expression
---

# $sortArray

The `$sortArray` operator is used to sort the elements of an array. The operator can be useful when you need to sort arrays within your documents based on specific fields or criteria. It can be applied to arrays of embedded documents or simple arrays of values.

## Syntax

```javascript
{
  $sortArray: {
    input: <arrayExpression>,
    sortBy: <sortSpecification>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The array to be sorted. |
| **`sortBy`** | Specifies the sort order. It can be a single field or multiple fields with their corresponding sort order (1 for ascending, -1 for descending). |

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

### Example 1: Sorting an Array of Embedded Documents

This query sorts the `sales.salesByCategory` array within each document in descending order based on `totalSales`.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "d3c9df51-41bd-4b4e-a26b-b038d9cf8b45"
    }
}, {
    $project: {
        sortedSalesByCategory: {
            $sortArray: {
                input: "$sales.salesByCategory",
                sortBy: {
                    totalSales: -1
                }
            }
        }
    }
}])
```

This query returns the following result.

```json
[
    {
        "_id": "d3c9df51-41bd-4b4e-a26b-b038d9cf8b45",
        "sortedSalesByCategory": [
            {
                "categoryName": "DJ Accessories",
                "totalSales": 60000
            },
            {
                "categoryName": "Music Accessories",
                "totalSales": 40000
            },
            {
                "categoryName": "DJ Speakers",
                "totalSales": 36972
            },
            {
                "categoryName": "DJ Headphones",
                "totalSales": 12877
            }
        ]
    }
]
```
