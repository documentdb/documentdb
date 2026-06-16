---
title: $sum
description: The $sum operator calculates the sum of the values of a field based on a filtering criteria
type: operators
category: accumulators
---

# $sum

The `$sum` operator calculates the sum of numeric values of a field or expression that match a filtering criteria.

## Syntax

```javascript
{
  $sum: <field or expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field or expression>`** | The field or expression to calculate the sum of. This can be a field, a numeric value, or an expression. |

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

### Example 1: Using `$sum` in `$group`

To compute total discount percentage per category across all promotion events in 2023:

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    {
        $match: {
            "promotionEvents.promotionalDates.startDate.Year": 2023
        }
    },
    {
        $group: {
            _id: "$promotionEvents.discounts.categoryName",
            totalDiscountIn2023: {
                $sum: "$promotionEvents.discounts.discountPercentage"
            }
        }
    },
    {
        $project: {
            _id: 0,
            categoryName: "$_id",
            totalDiscountIn2023: 1
        }
    }
])
```

This query returns the following results:

```json
[
    {
        "categoryName": "Glass Frames",
        "totalDiscountIn2023": 25
    },
    {
        "categoryName": "Picture Hanging Supplies",
        "totalDiscountIn2023": 14
    }
]
```

### Example 2:  Using `$sum` in `$bucket`

To get the total sales within defined sales boundaries:

```javascript
db.stores.aggregate([{
    $bucket: {
        groupBy: "$sales.totalSales", // Field to group by
        boundaries: [0, 10000, 20000, 50000, 100000], // Sales ranges
        default: "Other", // Default bucket for values outside the defined ranges
        output: {
            totalSalesSum: {
                $sum: "$sales.totalSales"
            }, // Sum the sales for each bucket
            count: {
                $sum: 1
            } // Count the number of documents in each bucket
        }
    }
}])
```

This query returns the following results:

```json
[
    {
        "_id": "Other",
        "totalSalesSum": 454981695,
        "count": 3001
    },
    {
        "_id": 0,
        "totalSalesSum": 20033725,
        "count": 3903
    },
    {
        "_id": 10000,
        "totalSalesSum": 71303703,
        "count": 4712
    },
    {
        "_id": 50000,
        "totalSalesSum": 756168541,
        "count": 11025
    },
    {
        "_id": 20000,
        "totalSalesSum": 678976078,
        "count": 18861
    }
]
```

### Example 3: Using `$sum` in `$setWindowFields`

To calculate the total discount per sales category for promotions in 2023:

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    {
        $match: {
            "promotionEvents.promotionalDates.startDate.Year": 2023
        }
    },
    {
        $setWindowFields: {
            partitionBy: "$promotionEvents.discounts.categoryName", // Group by categoryName
            output: {
                totalDiscountIn2023: {
                    $sum: "$promotionEvents.discounts.discountPercentage", // Sum discount percentage
                    window: {
                        documents: ["unbounded", "unbounded"] // Aggregate over all documents in the partition
                    }
                }
            }
        }
    },
    {
        $project: {
            _id: 0,
            categoryName: "$promotionEvents.discounts.categoryName",
            discountPercentage: "$promotionEvents.discounts.discountPercentage",
            totalDiscountIn2023: 1
        }
    },
    {
        $limit: 5
    }
])
```

This query returns the following results:

```json
[
    {
        "totalDiscountIn2023": 1106,
        "categoryName": "2-in-1 Laptops",
        "discountPercentage": 25
    },
    {
        "totalDiscountIn2023": 1106,
        "categoryName": "2-in-1 Laptops",
        "discountPercentage": 22
    },
    {
        "totalDiscountIn2023": 1106,
        "categoryName": "2-in-1 Laptops",
        "discountPercentage": 19
    },
    {
        "totalDiscountIn2023": 1106,
        "categoryName": "2-in-1 Laptops",
        "discountPercentage": 17
    },
    {
        "totalDiscountIn2023": 1106,
        "categoryName": "2-in-1 Laptops",
        "discountPercentage": 10
    }
]
```
