---
title: $concatArrays
description: The $concatArrays is used to combine multiple arrays into a single array.
type: operators
category: array-expression
---

# $concatArrays

The `$concatArrays` operator is used to combine multiple arrays into a single array. This operator is useful when you need to merge arrays from different documents or fields in a document.

## Syntax

```javascript
{
  $concatArrays: ["<array1>", "<array2>"]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<array1>, <array2>`**| The array fields targeted for concatenation.|

## Examples

Consider this sample document from the stores collection.

```json
{
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
    "location": {
        "lat": 60.1441,
        "lon": -141.5012
    },
    "staff": {
        "totalStaff": {
            "fullTime": 2,
            "partTime": 0
        }
    },
    "sales": {
        "salesByCategory": [
            {
                "categoryName": "DJ Headphones",
                "totalSales": 35921
            },
            {
                "categoryName": "DJ Cables",
                "totalSales": 1000
            }
        ],
        "fullSales": 3700
    },
    "promotionEvents": [
        {
            "eventName": "Bargain Blitz Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 3,
                    "Day": 11
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 2,
                    "Day": 18
                }
            },
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
            "eventName": "Discount Delight Days",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 5,
                    "Day": 11
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 5,
                    "Day": 18
                }
            }
        }
    ],
    "tag": [
        "#ShopLocal",
        "#FashionStore",
        "#SeasonalSale",
        "#FreeShipping",
        "#MembershipDeals"
    ]
}
```

### Example 1: Concatenating Arrays in a document

This query merges the `categoryName` field from the `promotionEvents.discounts` array with the `tag` array into a single combinedTags array.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
    }
}, {
    $project: {
        combinedTags: {
            $concatArrays: ["$promotionEvents.discounts.categoryName", "$tag"]
        }
    }
}])
```

This query returns the following result.

```json
[
  {
      "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
      "combinedTags": [ '#ShopLocal', '#NewArrival', '#NewArrival', '#FreeShipping' ]
  }
]
```
