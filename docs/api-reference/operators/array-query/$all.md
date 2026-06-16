---
title: $all
description: The $all operator helps finding array documents matching all the elements.
type: operators
category: array-query
---

# $all

The `$all` operator is used to select documents where the value of a field is an array that contains all the specified elements. This operator is useful when you need to ensure that an array field contains multiple specified elements, regardless of their order in the array.

## Syntax

```javascript
db.collection.find({
    field : {
        $all: [ < value1 > , < value2 > ]
    }
})
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to be queried. |
| **`<value1> , <value2>`** | The values that must all be present in the array field. |

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

### Example 1: Find documents containing all the specified elements in an array

This query retrieves documents containing both elements `Laptops` and `Smartphones` within `salesByCategory.categoryName` array.

```javascript
db.stores.find({
    "sales.salesByCategory.categoryName": {
        $all: ["Laptops", "Smartphones"]
    }
}, {
    _id: 1,
    "sales.salesByCategory.categoryName": 1
}).limit(2)
```

The first two results returned by this query are:

```json
[
    {
        "_id": "a57511bb-1ea3-4b26-bf0d-8bf928f2bfa8",
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Smartphones"
                },
                {
                    "categoryName": "Laptops"
                }
            ]
        }
    },
    {
        "_id": "ca56d696-5208-40c3-aa04-d4e245df44dd",
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Laptops"
                },
                {
                    "categoryName": "Smartphones"
                }
            ]
        }
    }
]
```
