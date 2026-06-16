---
title: $elemMatch
description: The $elemMatch operator returns complete array, qualifying criteria with at least one matching array element.
type: operators
category: array-query
---

# $elemMatch

The `$elemMatch` operator is used to match documents that contain an array field with at least one element that matches all the specified query criteria. This operator is useful when you need to find array documents with specified element.

## Syntax

```javascript
db.collection.find({ <field>: { $elemMatch: { <query1>, <query2>, ... } } })
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field in the document that contains the array to be queried. |
| **`query`** | The conditions that at least one element in the array must satisfy. |

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

### Example 1: Find in an array for specific element among the list of elements

This query retrieves the first two documents in the `stores` collection that have at least one discount with the category name "DJ Lighting" in their `promotionEvents` array. The query only returns the `_id` and `promotionEvents.discounts` fields for those documents.

```javascript
db.stores.find({
    "promotionEvents.discounts": {
        $elemMatch: {
            categoryName: "DJ Lighting"
        }
    }
}, {
    _id: 1,
    "promotionEvents.discounts": 1
}).limit(2)
```

This query returns the following results:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "promotionEvents": [
            {
                "discounts": [
                    {
                        "categoryName": "DJ Turntables",
                        "discountPercentage": 18
                    },
                    {
                        "categoryName": "DJ Mixers",
                        "discountPercentage": 15
                    }
                ]
            },
            {
                "discounts": [
                    {
                        "categoryName": "DJ Lighting",
                        "discountPercentage": 14
                    },
                    {
                        "categoryName": "DJ Cases",
                        "discountPercentage": 20
                    }
                ]
            }
        ]
    },
    {
        "_id": "91de5201-8194-44bf-848f-674e8df8bf5e",
        "promotionEvents": [
            {
                "discounts": [
                    {
                        "categoryName": "DJ Cases",
                        "discountPercentage": 6
                    },
                    {
                        "categoryName": "DJ Mixers",
                        "discountPercentage": 14
                    }
                ]
            },
            {
                "discounts": [
                    {
                        "categoryName": "DJ Headphones",
                        "discountPercentage": 19
                    },
                    {
                        "categoryName": "DJ Speakers",
                        "discountPercentage": 13
                    }
                ]
            },
            {
                "discounts": [
                    {
                        "categoryName": "DJ Lighting",
                        "discountPercentage": 12
                    },
                    {
                        "categoryName": "DJ Accessories",
                        "discountPercentage": 6
                    }
                ]
            }
        ]
    }
]
```
