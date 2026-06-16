---
title: $pull
description: Removes all instances of a value from an array.
type: operators
category: array-update
---

# $pull

The `$pull` operator is used to remove all instances of a specified value or values that match a condition from an array. This is useful when you need to clean up or modify array data within your documents.

## Syntax

```javascript
{
  $pull: { <field>: <value|condition> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field>`** | The field from which to remove one or more values. |
| **`<value|condition>`** | The value or condition to remove from the array. |

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

### Example 1: Remove a specific tag from the `tag` array

To remove the value "#SeasonalSale" from the tag array field, run a query using the $pull operator on the tag field.

```javascript
db.stores.update({
    _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
}, {
    $pull: {
        tag: "#SeasonalSale"
    }
})
```

This query returns the following result.

```json
[
  {
    "acknowledged": true,
    "insertedId": null,
    "matchedCount": "1",
    "modifiedCount": "1",
    "upsertedCount": 0
  }
]
```

### Example 2: Remove all events from the `promotionEvents` array that end before a certain date

To remove all elements from the promotionEvents array where the endDate year is 2024 and the endDate month is earlier than March, run a query using the $pull operator on the promotionEvents field with the specified date values.

```javascript
db.stores.update({
            _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
        }, {
            $pull: {
                promotionEvents: {
                    "promotionalDates.endDate.Year": 2024,
                    "promotionalDates.endDate.Month": {
                        $lt: 3
                    }
                }
            }
        }
)
```

This query returns the following result.

```json
[
  {
    "acknowledged": true,
    "insertedId": null,
    "matchedCount": "1",
    "modifiedCount": "1",
    "upsertedCount": 0
  }
]
```
