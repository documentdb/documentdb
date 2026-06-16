---
title: $arrayElemAt
description: The $arrayElemAt returns the element at the specified array index.
type: operators
category: array-expression
---

# $arrayElemAt

The `$arrayElemAt` operator is used to return the element at the specified array index. This operator is helpful when you need to extract a specific element from an array within your documents.

## Syntax

```javascript
{
  $arrayElemAt: ["<array>", <idx>]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<array>`**| The array reference from which the element is retrieved.|
| **`<idx>`**| The index of the element to return. The index is zero-based. A negative index counts from the end of the array.|

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
                "categoryName": "DJ Cables",
                "totalSales": 1000
            },
            {
                "categoryName": "DJ Headphones",
                "totalSales": 35921
            }
        ],
        "fullSales": 3700
    },
    "promotionEvents": [
        {
            "eventName": "Cyber Monday Event",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 8,
                    "Day": 1
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 8,
                    "Day": 7
                }
            },
            "discounts": [
                {
                    "categoryName": "DJ Speakers",
                    "discountPercentage": 25
                }
            ]
        },
        {
            "eventName": "Black Friday Event",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 8,
                    "Day": 1
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 8,
                    "Day": 7
                }
            },
            "discounts": [
                {
                    "categoryName": "DJ Speakers",
                    "discountPercentage": 25
                }
            ]
        },
        {
            "eventName": "Mega Discount Days",
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
            },
            "discounts": [
                {
                    "categoryName": "DJ Lights",
                    "discountPercentage": 20
                }
            ]
        }
    ],
    "tag": [
        "#ShopLocal",
        "#NewArrival",
        "#FashionStore",
        "#SeasonalSale",
        "#FreeShipping",
        "#MembershipDeals"
    ]
}

```

### Example 1: Return the first element from an array field

This query retrieves the first event details from `promotionEvents` array for the searched store.

```javascript
db.stores.aggregate([
  { $match: { name: "Lakeshore Retail | DJ Equipment Stop - Port Cecile" } },
  {
    $project: {
      firstPromotionEvent: { $arrayElemAt: ["$promotionEvents", 0] } 
    }
  }
])
```

This query returns the following result.

```json
[
  {
      "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
      "firstPromotionEvent": {
          "eventName": "Cyber Monday Event",
          "promotionalDates": {
              "startDate": {
                  "Year": 2024,
                  "Month": 8,
                  "Day": 1
              },
              "endDate": {
                  "Year": 2024,
                  "Month": 8,
                  "Day": 7
              }
          },
          "discounts": [
              {
                  "categoryName": "DJ Speakers",
                  "discountPercentage": 25
              }
          ]
      }
  }
]
```
