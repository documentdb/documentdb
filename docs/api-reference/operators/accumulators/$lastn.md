---
title: $lastN
description: The $lastN accumulator operator returns the last N values in a group of documents.
type: operators
category: accumulators
---

# $lastN

The `$lastN` accumulator operator returns the last N values in a group of documents for a specified expression. It's useful when you need to retrieve multiple final values from a sorted collection rather than just the single last value.

## Syntax

```javascript
{
    $group: {
        _id: < expression > ,
        < field >: {
            $lastN: {
                 n: < number >,
                 input: < expression >               
            }
        }
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`n`** | The number of values to return. Must be a positive integer. |
| **`input`** | The expression that specifies the field or value to return the last N occurrences of. |

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

### Example 1: Use $lastN as accumulator to find last two promotion events by store

To retrieve the last two promotion events for each store, run a query to sort promotion events in ascending order of their start dates, group the sorted events by store and return the last two events within each store.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $sort: {
            "promotionEvents.promotionalDates.startDate.Year": 1,
            "promotionEvents.promotionalDates.startDate.Month": 1,
            "promotionEvents.promotionalDates.startDate.Day": 1
        }
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $last: "$name"
            },
            lastTwoPromotions: {
                $lastN: {
                    input: "$promotionEvents.eventName",
                    n: 2
                }
            },
            lastTwoPromotionDates: {
                $lastN: {
                    input: "$promotionEvents.promotionalDates.startDate",
                    n: 2
                }
            }
        }
    }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "e28fff9b-a8fb-4ac9-bb37-dea60d2a7d32",
        "storeName": "Lakeshore Retail | Outdoor Furniture Collection - Erdmanside",
        "lastTwoPromotions": [
            "Big Bargain Bash",
            "Spectacular Savings Showcase"
        ],
        "lastTwoPromotionDates": [
            {
                "Year": 2024,
                "Month": 9,
                "Day": 21
            },
            {
                "Year": 2024,
                "Month": 6,
                "Day": 23
            }
        ]
    },
    {
        "_id": "1bec7539-dc75-4f7e-b4e8-afdf8ff2f234",
        "storeName": "Adatum Corporation | Health Food Market - East Karina",
        "lastTwoPromotions": [
            "Price Slash Spectacular",
            "Spectacular Savings Showcase"
        ],
        "lastTwoPromotionDates": [
            {
                "Year": 2024,
                "Month": 9,
                "Day": 21
            },
            {
                "Year": 2024,
                "Month": 6,
                "Day": 23
            }
        ]
    }
]
```

### Example 2: Use $lastN as accumulator to find the three highest selling categories of sales

To retrieve the highest selling sales categories per store, run a query to sort sales categories in ascending order of sales volume, group the sorted results by store and return the last three categories per store.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $sort: {
            "sales.salesByCategory.totalSales": 1
        }
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $last: "$name"
            },
            top3Categories: {
                $lastN: {
                    input: "$sales.salesByCategory.categoryName",
                    n: 3
                }
            },
            top3SalesAmounts: {
                $lastN: {
                    input: "$sales.salesByCategory.totalSales",
                    n: 3
                }
            }
        }
    }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "22e6367e-8341-415f-9795-118d2b522abf",
        "storeName": "Adatum Corporation | Outdoor Furniture Mart - Port Simone",
        "top3Categories": [
            "Outdoor Benches"
        ],
        "top3SalesAmounts": [
            4976
        ]
    },
    {
        "_id": "a00a3ccd-49a2-4e43-b0d9-e56b96113ed0",
        "storeName": "Wide World Importers | Smart Home Deals - Marcuschester",
        "top3Categories": [
            "Smart Thermostats",
            "Smart Plugs"
        ],
        "top3SalesAmounts": [
            38696,
            633
        ]
    }
]
```

### Example 3: Use $lastN operator as array-expression to get last two promotion events

The example demonstrates the operator usage to find the last or most recent two promotion events from a store.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      lastTwoPromotions: {
        $lastN: {
          input: "$promotionEvents",
          n: 2
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
      "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
      "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
      "lastTwoPromotions": [
          {
              "eventName": "Grand Deal Days",
              "promotionalDates": {
                  "startDate": {
                      "Year": 2024,
                      "Month": 6,
                      "Day": 23
                  },
                  "endDate": {
                      "Year": 2024,
                      "Month": 6,
                      "Day": 30
                  }
              },
              "discounts": [
                  {
                      "categoryName": "Remote Controls",
                      "discountPercentage": 7
                  },
                  {
                      "categoryName": "Televisions",
                      "discountPercentage": 11
                  },
                  {
                      "categoryName": "Business Projectors",
                      "discountPercentage": 13
                  },
                  {
                      "categoryName": "Laser Projectors",
                      "discountPercentage": 6
                  },
                  {
                      "categoryName": "Projectors",
                      "discountPercentage": 6
                  },
                  {
                      "categoryName": "Projector Screens",
                      "discountPercentage": 24
                  }
              ]
          },
          {
              "eventName": "Major Bargain Bash",
              "promotionalDates": {
                  "startDate": {
                      "Year": 2024,
                      "Month": 9,
                      "Day": 21
                  },
                  "endDate": {
                      "Year": 2024,
                      "Month": 9,
                      "Day": 30
                  }
              },
              "discounts": [
                  {
                      "categoryName": "Sound Bars",
                      "discountPercentage": 9
                  },
                  {
                      "categoryName": "VR Games",
                      "discountPercentage": 7
                  },
                  {
                      "categoryName": "Xbox Games",
                      "discountPercentage": 25
                  },
                  {
                      "categoryName": "Projector Accessories",
                      "discountPercentage": 18
                  },
                  {
                      "categoryName": "Mobile Games",
                      "discountPercentage": 8
                  },
                  {
                      "categoryName": "Projector Cases",
                      "discountPercentage": 22
                  }
              ]
          }
      ]
  }
]
```
