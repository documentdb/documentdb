---
title: $each
description: The $each operator is used within an `$addToSet` or `$push` operation to add multiple elements to an array field in a single update operation.
type: operators
category: array-update
---

# $each

The `$each` operator is used within an `$addToSet` or `$push` operation to add multiple elements to an array field in a single update operation. This operator is useful when you need to insert multiple items into an array without having to perform multiple update operations. The `$each` operator ensures that each item in the specified array is added to the target array.

## Syntax

```javascript
{
  $push: {
    <field>: {
      $each: [ <value1>, <value2>],
      <modifier1>: <value1>,
      <modifier2>: <value2>
    }
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field>`**| The field to be updated.|
| **`$each`**| An array of values to be added to the array field.|
| **`<modifier>`**| Optional modifiers like `$sort`, `$slice`, and `$position` to control the behavior of the `$push` operation.|

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

### Example 1: Add multiple elements to an array

This query adds multiple new promotion events to the `promotionEvents` array.

```javascript
db.stores.updateOne({
    name: "Lenore's New DJ Equipment Store"
}, {
    $push: {
        promotionEvents: {
            $each: [{
                    eventName: "Grand Savings",
                    promotionalDates: {
                        startDate: "2024-08-01",
                        endDate: "2024-08-31"
                    },
                    discounts: [{
                        categoryName: "DJ Headphones",
                        discountPercentage: 5
                    }]
                },
                {
                    eventName: "Big Bargain",
                    promotionalDates: {
                        startDate: "2024-11-25",
                        endDate: "2024-11-30"
                    },
                    discounts: [{
                        categoryName: "DJ Headphones",
                        discountPercentage: 20
                    }]
                }
            ]
        }
    }
})
```

This query returns the following result.

```json
[
  {
    "acknowledged": true,
    "insertedId": null,
    "matchedCount": "0",
    "modifiedCount": "0",
    "upsertedCount": 0
  }
]
```
