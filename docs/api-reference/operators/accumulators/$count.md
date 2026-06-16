---
title: $count
description: The `$count` operator is used to count the number of documents that match a query filtering criteria.
type: operators
category: accumulators
---

# $count

The `$count` operator is used to count the number of documents that match a specified query filter. The count operator is useful for summarizing data or generating counts for specific groupings.

## Syntax

```javascript
{
    $count: "<fieldName>"
}
```

## Parameters

| Parameter      | Description                                                                 |
|----------------|-----------------------------------------------------------------------------|
| **`<fieldName>`** | The name of the field in the output document where the count will be stored.|

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

### Example 1: Retrieve the count of all documents

To retrieve the count of documents within the collection, simply run a count query without query filters.

```javascript
db.stores.aggregate([{
    $count: "totalDocuments"
}])
```

This query returns the following result:

```json
[
    {
        "totalDocuments": 41501
    }
]
```

### Example 2: Count documents grouped by a specific field

To retrieve the count of documents within each sales category, first run a query to group documents by sales category. Then run a count query within each category.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $group: {
            _id: "$sales.salesByCategory.categoryName",
            totalCount: {
                $count: {}
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
        "totalCount": 93
    },
    {
        "_id": "Nuts",
        "totalCount": 83
    },
    {
        "_id": "Camping Tables",
        "totalCount": 130
    },
    {
        "_id": "Music Theory Books",
        "totalCount": 52
    },
    {
        "_id": "Fortified Wine",
        "totalCount": 55
    },
    {
        "_id": "Children's Mystery",
        "totalCount": 45
    },
    {
        "_id": "Short Throw Projectors",
        "totalCount": 72
    },
    {
        "_id": "Pliers",
        "totalCount": 56
    },
    {
        "_id": "Bluetooth Headphones",
        "totalCount": 104
    },
    {
        "_id": "Video Storage",
        "totalCount": 80
    },
    {
        "_id": "Cleansers",
        "totalCount": 68
    },
    {
        "_id": "Camera Straps",
        "totalCount": 64
    },
    {
        "_id": "Carry-On Bags",
        "totalCount": 57
    },
    {
        "_id": "Disinfectant Wipes",
        "totalCount": 85
    },
    {
        "_id": "Insignia Smart TVs",
        "totalCount": 81
    },
    {
        "_id": "Toner Refill Kits",
        "totalCount": 38
    },
    {
        "_id": "iPads",
        "totalCount": 51
    },
    {
        "_id": "Memory Foam Mattresses",
        "totalCount": 58
    },
    {
        "_id": "Storage Baskets",
        "totalCount": 68
    },
    {
        "_id": "Body Spray",
        "totalCount": 96
    }
]
```

### Example 3: Count the number of promotion events

To count the number of promotion events across all stores, first run a query to first unwind by promotion events and then count the distinct promotion events.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $count: "totalPromotionEvents"
    }
])
```

This query returns the following result:

```json
[
    {
        "totalPromotionEvents": 145673
    }
]
```

### Example 4: Using `$count` in `$setWindowFields`

To get sales for Laptops promotions per store, first run a query to filter promotion events for laptops in 2023. Then partition the resulting stores by company. Lastly, run a count query across the partitioned stores to return the results.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $unwind: "$promotionEvents.discounts"
    },
    // Filter only for Laptop discounts in 2023
    {
        $match: {
            "promotionEvents.promotionalDates.startDate.Year": 2023,
            "promotionEvents.discounts.categoryName": "Laptops"
        }
    },
    // Add sales count by city using window function
    {
        $setWindowFields: {
            partitionBy: "$company",
            output: {
                salesCount: {
                    $count: {},
                    window: {
                        documents: ["unbounded", "unbounded"]
                    }
                }
            }
        }
    },
    // Group to return a single result per city
    {
        $group: {
            _id: "$company",
            salesCount: {
                $first: "$salesCount"
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
        "salesCount": 13
    },
    {
        "_id": "Proseware, Inc.",
        "salesCount": 12
    },
    {
        "_id": "Fabrikam, Inc.",
        "salesCount": 11
    },
    {
        "_id": "Contoso, Ltd.",
        "salesCount": 13
    },
    {
        "_id": "Fourth Coffee",
        "salesCount": 8
    },
    {
        "_id": "Trey Research",
        "salesCount": 14
    },
    {
        "_id": "Adatum Corporation",
        "salesCount": 12
    },
    {
        "_id": "Relecloud",
        "salesCount": 16
    },
    {
        "_id": "Lakeshore Retail",
        "salesCount": 13
    },
    {
        "_id": "Northwind Traders",
        "salesCount": 5
    },
    {
        "_id": "First Up Consultants",
        "salesCount": 4
    },
    {
        "_id": "Wide World Importers",
        "salesCount": 7
    },
    {
        "_id": "Tailwind Traders",
        "salesCount": 12
    }
]
```
