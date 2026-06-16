---
title: $filter
description: The $filter operator filters for elements from an array based on a specified condition.
type: operators
category: array-expression
---

# $filter

The `$filter` operator is used to filter elements from an array based on a specified condition. This operator is useful when you need to manipulate or retrieve specific array elements within documents.

## Syntax

```javascript
{
  $filter: {
    input: "<array>",
    as: "<string>",
    cond: "<expression>"
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`**| An expression that resolves to an array.|
| **`as`**| A string that specifies the variable name for each element in the input array.|
| **`cond`**| An expression that determines whether to include the element in the output array.|

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

### Example 1: Retrieve an element filtered on condition

This query demonstrates how to filter sales category based on `totalSales`.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
        }
    },
    {
        $project: {
            filteredSalesByCategory: {
                $filter: {
                    input: "$sales.salesByCategory",
                    as: "item",
                    cond: {
                        $gt: ["$$item.totalSales", 10000]
                    }
                }
            }
        }
    }
])
```

This query returns the following result.

```json
[
  {
      "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
      "filteredSalesByCategory": [
          {
              "categoryName": "DJ Headphones",
              "totalSales": 35921
          }
      ]
  }
]
```
