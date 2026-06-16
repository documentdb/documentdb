---
title: $rank
description: The $rank operator ranks documents within a partition based on a specified sort order.
type: operators
category: window-operators
---

# $rank

The `$rank` operator assigns a rank to each document within a partition of a dataset. The rank is determined based on a specified sort order.

## Syntax

```javascript
{
    $setWindowFields: {
        partitionBy: < expression > ,
        sortBy: {
            < field >: < order >
        },
        output: {
            < outputField >: {
                $rank: {}
            }
        }
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`partitionBy`** | Specifies the expression to group documents into partitions. If omitted, all documents are treated as a single partition. |
| **`sortBy`** | Defines the sort order for ranking. Must be specified for `$rank`. |
| **`output`** | Contains the field where the rank value is stored. |

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

### Example 1: Ranking stores by sales volume

To rank all stores within the "First Up Consultants" company by sales volume, first run a query to partition the stores within the company. Then, sort the resulting stores in ascending order of sales volume and use the $rank operator to rank the sorted documents in the result set.

```javascript
db.stores.aggregate([{
    "$match": {
        "company": {
            "$in": ["First Up Consultants"]
        }
    }
}, {
    "$setWindowFields": {
        "partitionBy": "$company",
        "sortBy": {
            "sales.totalSales": -1
        },
        "output": {
            "rankBySales": {
                "$rank": {}
            }
        }
    }
}, {
    "$project": {
        "company": 1,
        "name": 1,
        "rankBySales": 1
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "a0386810-b6f8-4b05-9d60-e536fb2b0026",
        "name": "First Up Consultants | Electronics Stop - South Thelma",
        "company": "First Up Consultants",
        "rankBySales": 1
    },
    {
        "_id": "ad8af64a-d5bb-4162-9bb6-e5104126566d",
        "name": "First Up Consultants | Electronics Emporium - South Carmenview",
        "company": "First Up Consultants",
        "rankBySales": 2
    },
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "name": "First Up Consultants | Bed and Bath Pantry - Port Antone",
        "company": "First Up Consultants",
        "rankBySales": 3
    }
]
```
