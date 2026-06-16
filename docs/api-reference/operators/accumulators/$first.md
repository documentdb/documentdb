---
title: $first
description: The $first operator returns the first value in a group according to the group's sorting order.
type: operators
category: accumulators
---

# $first

The $first operator sorts documents on one or more fields specified by the query and returns the first document matching the filtering criteria. If no sorting order is specified, the order is undefined.

## Syntax

```javascript
{
    $first: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | The expression to evaluate and return the first document from the result set|

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

### Example 1: Get the least recently updated document

To retrieve the least recently updated store under the First Up Consultants company, run a query to fetch all documents belonging to the "First Up Consultants" company, sort the resulting documents in ascending order of the lastUpdated field and return the first document in the result set.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $sort: {
        lastUpdated: 1
    }
}, {
    $group: {
        _id: "$company",
        firstUpdated: {
            $first: "$lastUpdated"
        }
    }
}])
```

This query returns the following result:

```json
[
  {
      "_id": "First Up Consultants",
      "firstUpdated": "ISODate('2025-06-11T10:48:01.291Z')"
  }
]
```

### Example 2: Get first category by sales amount per store

To retrieve the first category (alphabetically) within each store, run a query to sort the list of sales categories within each store and return the first category from the sorted result set per store.

```javascript
db.stores.aggregate([{
        $unwind: "$sales.salesByCategory"
    },
    {
        $sort: {
            "_id": 1,
            "sales.salesByCategory.categoryName": 1
        }
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $first: "$name"
            },
            totalSales: {
                $first: "$sales.totalSales"
            },
            firstCategory: {
                $first: {
                    categoryName: "$sales.salesByCategory.categoryName",
                    categoryTotalSales: "$sales.salesByCategory.totalSales"
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
        "_id": "64ec6589-068a-44a6-be5b-9d37bb0a90f1",
        "storeName": "First Up Consultants | Computer Gallery - West Cathrine",
        "totalSales": 186829,
        "firstCategory": {
            "categoryName": "Cases",
            "categoryTotalSales": 36386
        }
    },
    {
        "_id": "14343900-2a5c-44bf-a52b-9efe63579866",
        "storeName": "Northwind Traders | Home Improvement Closet - West Evanside",
        "totalSales": 35371,
        "firstCategory": {
            "categoryName": "Doors",
            "categoryTotalSales": 21108
        }
    }
]
```

### Example 3: Get first promotion event per store

To retrieve the first promotion event for each store, run a query to sort the list of promotion events within each store by startDate and return the first event from the sorted result set per store.

Get the first promotion event for each store based on start date.

```javascript
db.stores.aggregate([{
        $unwind: "$promotionEvents"
    },
    {
        $sort: {
            "_id": 1,
            "promotionEvents.promotionalDates.startDate.Year": 1,
            "promotionEvents.promotionalDates.startDate.Month": 1,
            "promotionEvents.promotionalDates.startDate.Day": 1
        }
    },
    {
        $group: {
            _id: "$_id",
            storeName: {
                $first: "$name"
            },
            firstPromotionEvent: {
                $first: {
                    eventName: "$promotionEvents.eventName",
                    startYear: "$promotionEvents.promotionalDates.startDate.Year",
                    startMonth: "$promotionEvents.promotionalDates.startDate.Month"
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
        "_id": "64ec6589-068a-44a6-be5b-9d37bb0a90f1",
        "storeName": "First Up Consultants | Computer Gallery - West Cathrine",
        "firstPromotionEvent": {
            "eventName": "Crazy Markdown Madness",
            "startYear": 2024,
            "startMonth": 6
        }
    },
    {
        "_id": "a58d0356-493b-44e6-afab-260aa3296930",
        "storeName": "Fabrikam, Inc. | Outdoor Furniture Nook - West Lexie",
        "firstPromotionEvent": {
            "eventName": "Price Drop Palooza",
            "startYear": 2023,
            "startMonth": 9
        }
    }
]
```
