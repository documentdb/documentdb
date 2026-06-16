---
title: $bottom
description: The $bottom operator returns the last document from the query's result set sorted by one or more fields
type: operators
category: accumulators
---

# $bottom

The `$bottom` operator sorts documents on one or more fields specified by the query and returns the last document matching the filtering criteria.

## Syntax

```javascript
{
    $bottom: {
        output: [listOfFields],
        sortBy: {
            <fieldName>: < sortOrder >
        }
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`listOfFields`** | The list of fields to be returned from the last document in the result set|
| **`fieldName`** | The field to use for sorting the result set|
| **`sortOrder`** | 1 or -1. 1 implies sorting in ascending order of the value of the field while -1 implies sorting in descending order of the values of the field|

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

### Example 1: Find the store with lowest total sales

Suppose we want to determine the store within the First Up Consultants company with the lowest total sales, run a query to retrieve documents within the First Up Consultants company, sort the documents in descending order of total sales and return the last document in the sorted result set.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $group: {
        _id: "$company",
        bottomSales: {
            $bottom: {
                output: ["$company", "$sales"],
                sortBy: {
                    "sales.revenue": -1
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
    "_id": "First Up Consultants",
    "bottomSales": [
        "First Up Consultants",
        {
            "totalSales": 119,
            "salesByCategory": [
                {
                    "categoryName": "Skirts",
                    "totalSales": 109
                }
            ]
        }
    ]
}]
```

### Example 2: Find the category per store with the lowest sales

To find the category with the lowest sales per store, run a query to retrieve stores with multiple sales categories, sort the categories in descending order of total sales within each store and return the last document in the sorted result set.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $match: {
            "sales.salesByCategory.totalSales": {
                $exists: true
            }
        }
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $first: "$name"
            },
            lowestCategory: {
                $bottom: {
                    sortBy: {
                        "sales.salesByCategory.totalSales": 1
                    },
                    output: {
                        categoryName: "$sales.salesByCategory.categoryName",
                        totalSales: "$sales.salesByCategory.totalSales"
                    }
                }
            }
        }
    }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "b1d86d1f-8705-4157-b64c-a9eda0df4921",
    "storeName": "VanArsdel, Ltd. | Baby Products Haven - West Kingfort",
    "lowestCategory": { "categoryName": "Baby Monitors", "totalSales": 49585 }
  },
  {
    "_id": "22e6367e-8341-415f-9795-118d2b522abf",
    "storeName": "Adatum Corporation | Outdoor Furniture Mart - Port Simone",
    "lowestCategory": { "categoryName": "Outdoor Benches", "totalSales": 4976 }
  }
]
```
