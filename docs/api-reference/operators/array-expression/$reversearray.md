---
title: $reverseArray
description: The $reverseArray operator is used to reverse the order of elements in an array.
type: operators
category: array-expression
---

# $reverseArray

The `$reverseArray` operator is used to reverse the order of elements in an array. This operator can be useful when you need to process or display array elements in the opposite order. It's an array expression operator and can be used within aggregation pipelines.

## Syntax

```javascript
{
  $reverseArray: <array>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<array>`**| The array that you want to reverse.|

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

### Example 1: Reversing the order of an array

This query demonstrates the usage of operator for performing reversal on the order of the `promotionEvents` array.

```javascript
db.stores.aggregate([
    //filtering to one document
    {
        $match: {
            _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
        }
    },
    {
        $project: {
            _id: 1,
            name: 1,
            promotionEventsReversed: {
                $reverseArray: "$promotionEvents"
            }
        }
    },
    // Include only _id, name, promotionalDates and eventName fields in the output 
    {
        $project: {
            _id: 1,
            name: 1,
            "promotionEventsReversed.promotionalDates": 1,
            "promotionEventsReversed.eventName": 1
        }
    }
])
```

This query returns the following result.

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
        "promotionEventsReversed": [
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
            },
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
                }
            }
        ]
    }
]
```
