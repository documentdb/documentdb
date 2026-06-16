---
title: $pullAll
description: The $pullAll operator is used to remove all instances of the specified values from an array.
type: operators
category: array-update
---

# $pullAll

The `$pullAll` operator is used to remove all instances of the specified values from an array. This operator is useful when you need to clean up arrays by removing multiple specific elements in a single operation.

Both `$pull` and `$pullAll` are used to remove elements from an array, but they differ in how they identify the elements to be removed. `$pull` removes all elements from an array that match a specific condition, which can be a simple value or a more complex query (like matching sub-document fields). On the other hand, `$pullAll` removes specific values provided as an array of exact matches, but it doesn't support conditions or queries. Essentially, `$pull` is more flexible as it allows conditional removal based on various criteria, while `$pullAll` is simpler, working only with a fixed set of values.

## Syntax

```javascript
{
  $pullAll: { <field1>: [ <value1>, <value2>] }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field1>`**| The field where the specified values will be removed.|
| **`[ <value1>, <value2>, ... ]`**| An array of values to be removed from the specified field.|

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

### Example 1: Remove multiple elements from an array

To remove the discounts for "#MembershipDeals" and "#SeasonalSale" from the 'tag' array, run a query using the $pulAll operator on the tag field with the values to remove.

```javascript
db.stores.updateMany(
    //filter
    { _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"},
    {
      $pullAll: {
        tag: ["#MembershipDeals","#SeasonalSale" ]
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
    "matchedCount": 1,
    "modifiedCount": 1,
    "upsertedCount": 0
  }
]
```
