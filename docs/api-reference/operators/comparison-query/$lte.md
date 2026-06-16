---
title: $lte
description: The $lte operator retrieves documents where the value of a field is less than or equal to a specified value
type: operators
category: comparison-query
---

# $lte

The `$lte` operator retrieves documents where the value of a field is less than or equal to a specified value. The `$lte` operator filters documents based on numerical, date, or other comparable fields.

## Syntax

```javascript
{
    field: {
        $lte: <value>
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to be compared|
| **`value`** | The value to compare against|

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

### Example 1: Find a store with sales <= $35,000

To find a store with sales <= $35,000, run a query using $lte on the sales.totalSales field and limit the resulting documents to a single store.

```javascript
db.stores.find({
    "sales.totalSales": {
        $lte: 35000
    }
}, {
    _id: 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
  {
    "_id": "e6895a31-a5cd-4103-8889-3b95a864e5a6"
  }
]
```

### Example 2: Find a store with 12 or fewer full-time staff

To find a store with <= 12 full-time staff, run a query using $lte on the nested fullTime field. Then project only the name and full time staff count and limit the results to one store from the result set.

```javascript
db.stores.find({
    "staff.totalStaff.fullTime": {
        $lte: 12
    }
}, {
    name: 1,
    "staff.totalStaff.fullTime": 1
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
      "staff": { "totalStaff": { "fullTime": 6 } }
  }
]
```
