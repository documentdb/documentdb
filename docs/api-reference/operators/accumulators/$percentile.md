---
title: $percentile
description: The $percentile operator calculates the percentile of numerical values that match a filtering criteria
type: operators
category: accumulators
---

# $percentile

The `$percentile` operator calculates the percentile of numerical values that match a filtering criteria. This operator is particularly useful for identifying statistical thresholds, such as median or percentiles.

## Syntax

```javascript
$percentile: {
    input: < field or expression > ,
    p: [ < percentile values > ],
    method: < method >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | Specifies the numerical data to calculate the percentile from. |
| **`p`** | An array of percentile values (between 0 and 1) to calculate. |
| **`method`** | Specifies the interpolation method to use. Valid values are `"approximate"` and `"continuous"`. |

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

### Example 1: Calculate the 50th percentile of sales volume

This query calculates the 50th percentile (median) of total sales volume within each sales category across all stores.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $group: {
            _id: null,
            medianSales: {
                $percentile: {
                    input: "$sales.salesByCategory.totalSales",
                    p: [0.5],
                    method: "approximate"
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
        "_id": null,
        "medianSales": [
            25070.449624139295
        ]
    }
]
```

### Example 2: Calculate multiple percentiles

This query calculates the 25th, 50th, and 75th percentiles of the total sales across all stores.

```javascript
db.stores.aggregate([{
    $group: {
        _id: null,
        percentiles: {
            $percentile: {
                input: "$sales.fullSales",
                p: [0.25, 0.5, 0.75],
                method: "approximate"
            }
        }
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": null,
        "percentiles": [
            3700,
            3700,
            3700
        ]
    }
]
```
