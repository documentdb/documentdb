---
title: $cmp
description: The $cmp operator compares two values
type: operators
category: comparison-query
---

# $cmp

The `$cmp` operator compares two specified values. The $cmp operator returns -1 if the first value is less than the second, 0 if the two values are equal and 1 if the first value is greater than the second.

## Syntax

```javascript
{
  $cmp: [<firstValueToCompare>, <secondValueToCompare>]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<firstValueToCompare>`** | The first value which is compared to the second by the $cmp operator|
| **`<secondValueToCompare>`** | The second value being compared to by the $cmp operator|

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

### Example 1 - Compare the total sales of stores to $25,000

To compare the total sales of stores within the Boulder Innovations Company to $25,000, first run a query to filter on the company name of stores. Then, use $cmp to compare the sales.totalSales field to 25000. Lastly, project only the name and total sales for the resulting stores.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["Boulder Innovations"]
        }
    }
}, {
    $project: {
        name: 1,
        "sales.salesByCategory.totalSales": 1,
        greaterThan25000: {
            $cmp: ["$sales.revenue", 25000]
        }
    }
}])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "a5040801-d127-4950-a320-e55f6aed4b36",
        "name": "Boulder Innovations | DJ Equipment Pantry - West Christopher",
        "sales": {
            "salesByCategory": [
                {
                    "totalSales": 21522
                }
            ]
        },
        "greaterThan25000": -1
    },
    {
        "_id": "bb6e097a-e204-4b64-9f13-5ae8426fcc76",
        "name": "Boulder Innovations | Kitchen Appliance Outlet - Lake Chazville",
        "sales": {
            "salesByCategory": [
                {
                    "totalSales": 24062
                },
                {
                    "totalSales": 24815
                }
            ]
        },
        "greaterThan25000": 1
    }
]
```
