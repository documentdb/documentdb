---
title: $ne
description: The $ne operator retrieves documents where the value of a field doesn't equal a specified value
type: operators
category: comparison-query
---

# $ne

The `$ne` operator retrieves documents where the value of a field doesn't equal a specified value.

## Syntax

```javascript
{
    field: {
        $ne: value
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to be compared|
| **`value`** | The value that the field shouldn't be equal to|

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

### Example 1 - Find a store whose name isn't "Fourth Coffee"

To find a store with a name that isn't "Fourth Coffee", first run a query using $ne on the name field. Then project only the name of the resulting documents and limit the results to one store from the result set.

```javascript
db.stores.find({
    name: {
        $ne: "Fourth Coffee"
    }
}, {
    _id: 1,
    name: 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "name": "First Up Consultants | Bed and Bath Center - South Amir"
    }
]
```

### Example 2 - Find a store with promotion events that aren't in 2024

To find a store with promotions events that don't start in 2024, first run a query using $ne on the nested startDate field. Then project the name and promotions offered by the stores and limit the results to one document from the result set.

```javascript
db.stores.find({
    "promotionEvents.promotionalDates.startDate": {
        $ne: "2024"
    }
}, {
    name: 1,
    "promotionEvents.promotionalDates.startDate": 1
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
        "promotionEvents": [
          {
            "promotionalDates": { "startDate": { "Year": 2024, "Month": 9, "Day": 21 } }
          }
        ]
    }
]
```
