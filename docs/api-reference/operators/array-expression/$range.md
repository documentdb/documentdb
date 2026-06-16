---
title: $range
description: The $range operator allows generating an array of sequential integers.
type: operators
category: array-expression
---

# $range

The `$range` operator is used to generate an array of sequential integers. The operator helps create number arrays in a range, useful for pagination, indexing, or test data.

## Syntax

```javascript
{
    $range: [ <start>, <end>, <step> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`start`** | The starting value of the range (inclusive). |
| **`end`** | The ending value of the range (exclusive). |
| **`step`** | The increment value between each number in the range (optional, defaults to 1). |

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

### Example 1: Generate a range of numbers

This query demonstrates usage of operator to generate an array of integers from 0 to 5, wherein it includes the left boundary while excludes the right.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6"
    }
}, {
    $project: {
        rangeArray: {
            $range: [0, 5]
        }
    }
}])
```

This query returns the following result.

```json
[
    {
        "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
        "rangeArray": [
            0,
            1,
            2,
            3,
            4
        ]
    }
]
```

### Example 2: Generate a range of numbers with a step value

This query demonstrates usage of operator to generate an array of even numbers from 0 to 18.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6"
    }
}, {
    $project: {
        evenNumbers: {
            $range: [0, 8, 2]
        }
    }
}])
```

This query results the following result.

```json
[
    {
        "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
        "rangeArray": [
            0,
            2,
            4,
            6
        ]
    }
]
```
