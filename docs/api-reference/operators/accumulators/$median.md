---
title: $median
description: The $median operator calculates the median value of a numeric field in a group of documents.
type: operators
category: accumulators
---

# $median usage on DocumentDB

The `$median` accumulator operator calculates the median value of a numeric field in a group of documents.

## Syntax

```javascript
{
    $group: {
        _id: < expression > ,
        medianValue: {
            $median: {
                input: < field or expression > ,
                method: < >
            }
        }
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field or expression>`** | The field or expression from which to calculate the median. |

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

### Example 1: Calculate the median sales volume

To calculate the median sales volume within each category, first group the documents by the distinct sales categories, then calculate the median sales within each grouped category.

```javascript
db.stores.aggregate([{
    $unwind: "$sales.salesByCategory"
}, {
    $group: {
        _id: "$sales.salesByCategory.categoryName",
        medianSales: {
            $median: {
                "input": "$sales.salesByCategory.totalSales",
                "method": "approximate"
            }
        }
    }
}])
```

The first five results returned by this query are:

```json
[
    {
        "_id": "Light Bulbs",
        "medianSales": 24845
    },
    {
        "_id": "Christmas Trees",
        "medianSales": 28210
    },
    {
        "_id": "Ukuleles",
        "medianSales": 27295
    },
    {
        "_id": "GPUs",
        "medianSales": 19813
    },
    {
        "_id": "Towels",
        "medianSales": 27771
    }
]
```
