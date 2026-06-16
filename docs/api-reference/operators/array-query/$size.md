---
title: $size
description: The $size operator is used to query documents where an array field has a specified number of elements.
type: operators
category: array-query
---

# $size

The `$size` operator is used to query documents where an array field has a specified number of elements. This operator is useful when you need to find documents based on the size of an array field, such as finding documents with some items in a list.

## Syntax

```javascript
db.collection.find({ <field>: { $size: <number> } })
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field that contains the array. |
| **`number`** | The number of elements the array should have. |

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

### Example 1: Finding documents with a specific number of elements in an array

This query retrieves documents from the `stores` collection where the `sales.salesByCategory` array contains exactly seven items.

```javascript
db.stores.find({
    "sales.salesByCategory": {
        $size: 7
    }
}, {
    _id: 1,
    name: 1,
    "sales.salesByCategory": 1
}).limit(2)
```

This query returns the following results:

```json
[
    {
        "_id": "7ed4b356-1290-433e-bd96-bf95f817eaaa",
        "name": "Wide World Importers",
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Ultrabooks",
                    "totalSales": 31304
                },
                {
                    "categoryName": "Laptop Accessories",
                    "totalSales": 10044
                },
                {
                    "categoryName": "Laptops",
                    "totalSales": 48851
                },
                {
                    "categoryName": "Refill Kits",
                    "totalSales": 9604
                },
                {
                    "categoryName": "Prepaid Phones",
                    "totalSales": 28600
                },
                {
                    "categoryName": "Android Phones",
                    "totalSales": 4580
                },
                {
                    "categoryName": "Photo Printers",
                    "totalSales": 35234
                }
            ]
        }
    },
    {
        "_id": "988d2dd1-2faa-4072-b420-b91b95cbfd60",
        "name": "Lakeshore Retail",
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Towel Racks",
                    "totalSales": 13237
                },
                {
                    "categoryName": "Washcloths",
                    "totalSales": 44315
                },
                {
                    "categoryName": "Face Towels",
                    "totalSales": 42095
                },
                {
                    "categoryName": "Toothbrush Holders",
                    "totalSales": 47912
                },
                {
                    "categoryName": "Hybrid Mattresses",
                    "totalSales": 48660
                },
                {
                    "categoryName": "Napkins",
                    "totalSales": 31439
                },
                {
                    "categoryName": "Pillow Cases",
                    "totalSales": 38833
                }
            ]
        }
    }
]
```
