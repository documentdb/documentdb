---
title: $sort
description: The $sort stage in the aggregation pipeline is used to order the documents in the pipeline by a specified field or fields.
type: operators
category: aggregation
---

# $sort

The $sort stage in the aggregation pipeline is used to order the documents in the pipeline by a specified field or fields. This stage helps you sort data, like arranging sales by amount or events by date.

## Syntax

```javascript
{
    $sort: {
        < field1 >: < sort order > ,
        < field2 >: < sort order >
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to sort by |
| **`sort order`** | The order in which we should sort the field. 1 for ascending order and -1 for descending order. |

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

### Example 1: Sorting by total sales in sescending order

To sort the sales categories by their total sales in descending order:

```javascript
db.collection.aggregate([
  {
    $unwind: "$store.sales.salesByCategory"
  },
  {
    $sort: { "store.sales.salesByCategory.totalSales": -1 }
  }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "store": {
            "name": "Downtown Store",
            "sales": {
                "salesByCategory": [
                    {
                        "category": "Electronics",
                        "totalSales": 15000
                    },
                    {
                        "category": "Clothing",
                        "totalSales": 12000
                    },
                    {
                        "category": "Home Goods",
                        "totalSales": 10000
                    }
                ]
            }
        }
    },
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c6",
        "store": {
            "name": "Uptown Store",
            "sales": {
                "salesByCategory": [
                    {
                        "category": "Electronics",
                        "totalSales": 20000
                    },
                    {
                        "category": "Clothing",
                        "totalSales": 18000
                    },
                    {
                        "category": "Home Goods",
                        "totalSales": 15000
                    }
                ]
            }
        }
    }
]
```

### Example 2: Sorting by event start date in ascending order

To sort the promotion events by their start dates in ascending order:

```javascript
db.collection.aggregate([
  {
    $unwind: "$store.promotionEvents"
  },
  {
    $sort: { "store.promotionEvents.promotionalDates.startDate": 1 }
  }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "store": {
            "name": "Downtown Store",
            "promotionEvents": [
                {
                    "eventName": "Summer Sale",
                    "promotionalDates": {
                        "startDate": "2024-06-01T00:00:00Z",
                        "endDate": "2024-06-30T23:59:59Z"
                    }
                },
                {
                    "eventName": "Black Friday",
                    "promotionalDates": {
                        "startDate": "2024-11-25T00:00:00Z",
                        "endDate": "2024-11-25T23:59:59Z"
                    }
                },
                {
                    "eventName": "Holiday Deals",
                    "promotionalDates": {
                        "startDate": "2024-12-01T00:00:00Z",
                        "endDate": "2024-12-31T23:59:59Z"
                    }
                }
            ]
        }
    },
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c6",
        "store": {
            "name": "Uptown Store",
            "promotionEvents": [
                {
                    "eventName": "Back to School",
                    "promotionalDates": {
                        "startDate": "2024-08-01T00:00:00Z",
                        "endDate": "2024-08-31T23:59:59Z"
                    }
                },
                {
                    "eventName": "Winter Sale",
                    "promotionalDates": {
                        "startDate": "2024-12-01T00:00:00Z",
                        "endDate": "2024-12-31T23:59:59Z"
                    }
                }
            ]
        }
    }
]
```

### Example 3: Sorting an array of objects

The example sorts the `salesByCategory` array in place based on the `totalSales` field in ascending order.

```javascript
db.stores.updateOne({
            _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
        }, {
            $push: {
                "sales.salesByCategory": {
                    $each: [],
                    $sort: {
                        totalSales: 1
                    }
                }
            }
        }
)
```
