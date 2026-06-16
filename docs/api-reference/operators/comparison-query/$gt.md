---
title: $gt
description: The $gt query operator retrieves documents where the value of a field is greater than a specified value
type: operators
category: comparison-query
---

# $gt

The `$gt` operator retrieves documents where the value of a field is greater than a specified value. The `$gt` operator queries numerical and date values to filter records that exceed a specified threshold.

## Syntax

```javascript
{
    field: {
        $gt: value
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field in the document you want to compare|
| **`value`** | The value that the field should be greater than|

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

### Example 1: Retrieve stores with sales exceeding $35,000

To retrieve a store with over $35,000 in sales, first run a query with $gt operator on the sales.totalSales field. Then limit the query results to one store.

```javascript
db.stores.find({
    "sales.totalSales": {
        $gt: 35000
    }
}, {
    name: 1,
    "sales.totalSales": 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "sales": { "totalSales": 37701 }
    }
]
```

### Example 2: Find a store with more than 12 full-time staff

To find a store with more than 12 full time staff, first run a query with the $gt operator on the staff.totalStaff.fullTime field. Then project just the name and totalStaff fields and limit the result set to a single store from the list of matching results.

```javascript
db.stores.find({
    "staff.totalStaff.fullTime": {
        $gt: 12
    }
}, {
    name: 1,
    "staff.totalStaff": 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "staff": { "totalStaff": { "fullTime": 18, "partTime": 17 } }
    }
]
```
