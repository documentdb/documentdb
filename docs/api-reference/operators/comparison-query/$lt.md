---
title: $lt
description: The $lt operator retrieves documents where the value of field is less than a specified value
type: operators
category: comparison-query
---

# $lt

The `$lt` operator retrieves documents where the value of a field is strictly less than a specified value. The `$lt` operator filters documents based on numeric, date, or string values.

## Syntax

```javascript
{
    field: {
        $lt: value
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field in the document you want to evaluate|
| **`value`** | The value to compare against the field's value. The operator will match documents where the field's value is less than this specified value|

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

### Example 1: Find a store with sales below $36,000

To find a store with less than $36,000 in sales, first run a query using $lt on the sales.totalSales field. Then project only the name and total sales of the resulting stores and limit the number of results to a single document.

```javascript
db.stores.find({
    "sales.totalSales": {
        $lt: 36000
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
        "_id": "e6895a31-a5cd-4103-8889-3b95a864e5a6",
        "name": "VanArsdel, Ltd. | Picture Frame Store - Port Clevelandton",
        "sales": { "totalSales": 17676 }
    }
]
```
