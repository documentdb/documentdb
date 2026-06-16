---
title: $last
description: The $last operator returns the last document from the result sorted by one or more fields
type: operators
category: accumulators
---

# $last

The `$last` operator sorts documents on one or more fields specified by the query and returns the last document matching the filtering criteria.

## Syntax

```javascript
{
  "$last": <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | The expression to evaluate and return the last document from the result set|

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

### Example 1: Get the last updated store within a company

To retrieve the more recently updated store within the First Up Consultants company, run a query to fetch all stores within First Up Consultants, sort the documents in ascending order of the lastUpdated field and return the last document from the sorted results.

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
        lastUpdated: {
            $last: "$lastUpdated"
        }
    }
}])
```

This query returns the following result:

```json
[
  {
      "_id": "First Up Consultants",
      "lastUpdated": "ISODate('2024-12-31T13:01:19.097Z')"
  }
]
```

### Example 2 - Using the window operator

To retrieve the more recently updated store within each company, run a query to partition the results by the company field and sort the documents within each partition in ascending order of lastUpdated field and return the sorted results per partition.

```javascript
db.stores.aggregate([{
    $setWindowFields: {
        partitionBy: "$company",
        sortBy: {
            lastUpdated: 1
        },
        output: {
            lastUpdatedDateForStore: {
                $last: "$lastUpdated",
                window: {
                    documents: ["current", "unbounded"]
                }
            }
        }
    }
}])
```

The first result returned by this query is:

```json
[
  {
      "_id": "First Up Consultants",
      "lastUpdated": "ISODate('2024-12-31T13:01:19.097Z')"
  }
]
```
