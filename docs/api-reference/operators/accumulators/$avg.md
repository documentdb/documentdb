---
title: $avg
description: The $avg operator computes the average of numeric values for documents in a group, bucket, or window.
type: operators
category: accumulators
---

# $avg

The `$avg` operator computes the average of numeric values across groups of documents or within defined windows.

## Syntax

```javascript
$avg: <field or expression>
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field or expression>`** | Specifies the field or expression to calculate the average. Non-numeric values are ignored. |

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

### Example 1: Calculate the average sales by category

To calculate the average sales across all stores within each category, first run a query to group documents within each sales category. Then, calculate the average sales across all documents within each group.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $group: {
            _id: "$sales.salesByCategory.categoryName",
            avgSales: {
                $avg: "$sales.salesByCategory.totalSales"
            }
        }
    }
])
```

This query returns the following results:

```json
[
    {
        "_id": "Christmas Trees",
        "avgSales": 25987.956989247312
    },
    {
        "_id": "Nuts",
        "avgSales": 25115.98795180723
    },
    {
        "_id": "Camping Tables",
        "avgSales": 25012.546153846153
    },
    {
        "_id": "Music Theory Books",
        "avgSales": 26138.80769230769
    },
    {
        "_id": "Fortified Wine",
        "avgSales": 24748.672727272726
    },
    {
        "_id": "Children's Mystery",
        "avgSales": 23764.044444444444
    },
    {
        "_id": "Short Throw Projectors",
        "avgSales": 27157.472222222223
    },
    {
        "_id": "Pliers",
        "avgSales": 26712.875
    },
    {
        "_id": "Bluetooth Headphones",
        "avgSales": 26311.58653846154
    },
    {
        "_id": "Video Storage",
        "avgSales": 26121.475
    },
    {
        "_id": "Cleansers",
        "avgSales": 25836.397058823528
    },
    {
        "_id": "Camera Straps",
        "avgSales": 22487.609375
    },
    {
        "_id": "Carry-On Bags",
        "avgSales": 24294.263157894737
    },
    {
        "_id": "Disinfectant Wipes",
        "avgSales": 27066.929411764704
    },
    {
        "_id": "Insignia Smart TVs",
        "avgSales": 27096.83950617284
    },
    {
        "_id": "Toner Refill Kits",
        "avgSales": 24963.71052631579
    },
    {
        "_id": "iPads",
        "avgSales": 22583.882352941175
    },
    {
        "_id": "Memory Foam Mattresses",
        "avgSales": 28073.05172413793
    },
    {
        "_id": "Storage Baskets",
        "avgSales": 24092.514705882353
    },
    {
        "_id": "Body Spray",
        "avgSales": 26080.84375
    }
]
```

### Example 2: Using `$avg` in `$bucket`

To get the averages sales within specific sales boundaries, this query creates buckets based on sales values and calculates the avg sales within each bucket.

```javascript
db.stores.aggregate([{
    $bucket: {
        groupBy: "$sales.totalSales",
        boundaries: [0, 1000, 5000, 10000],
        default: "Other",
        output: {
            avgSales: {
                $avg: "$sales.totalSales"
            }
        }
    }
}])
```

This query returns the following results:

```json
[
    {
        "_id": 1000,
        "avgSales": 3029.053674121406
    },
    {
        "_id": "Other",
        "avgSales": 52169.85442987472
    },
    {
        "_id": 0,
        "avgSales": 576.3164179104477
    },
    {
        "_id": 5000,
        "avgSales": 7538.786819770345
    }
]
```

### Example 3: Using `$avg` in `$setWindowFields`

To get the average discount per store in 2023 for "Laptops", first run a query to partition stores by company and filter discount promotions for "Laptops". Then calculate the average discount percentage within each partitioned result set.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $unwind: "$promotionEvents.discounts"
    },

    // Filter only Laptops category and events in 2023
    {
        $match: {
            "promotionEvents.promotionalDates.startDate.Year": 2023,
            "promotionEvents.discounts.categoryName": "Laptops"
        }
    },

    // Use $setWindowFields to calculate average discount by city
    {
        $setWindowFields: {
            partitionBy: "$company",
            output: {
                avgDiscount: {
                    $avg: "$promotionEvents.discounts.discountPercentage",
                    window: {
                        documents: ["unbounded", "unbounded"]
                    }
                }
            }
        }
    },

    // Group by city to return one result per city
    {
        $group: {
            _id: "$company",
            avgDiscount: {
                $first: "$avgDiscount"
            }
        }
    }
])
```

This query returns the following results:

```json
[
    {
        "_id": "VanArsdel, Ltd.",
        "avgDiscount": 14.461538461538462
    },
    {
        "_id": "Proseware, Inc.",
        "avgDiscount": 16.25
    },
    {
        "_id": "Fabrikam, Inc.",
        "avgDiscount": 14.454545454545455
    },
    {
        "_id": "Contoso, Ltd.",
        "avgDiscount": 14.384615384615385
    },
    {
        "_id": "Fourth Coffee",
        "avgDiscount": 13.625
    },
    {
        "_id": "Trey Research",
        "avgDiscount": 17.785714285714285
    },
    {
        "_id": "Adatum Corporation",
        "avgDiscount": 11.666666666666666
    },
    {
        "_id": "Relecloud",
        "avgDiscount": 14.375
    },
    {
        "_id": "Lakeshore Retail",
        "avgDiscount": 15.846153846153847
    },
    {
        "_id": "Northwind Traders",
        "avgDiscount": 14.2
    },
    {
        "_id": "First Up Consultants",
        "avgDiscount": 11.25
    },
    {
        "_id": "Wide World Importers",
        "avgDiscount": 15.571428571428571
    },
    {
        "_id": "Tailwind Traders",
        "avgDiscount": 16.166666666666668
    }
]
```
