---
title: $documents
description: The $documents stage creates a pipeline from a set of provided documents.
type: operators
category: aggregation
---

# $documents

The `$documents` aggregation pipeline stage is used to create a pipeline from a set of provided documents. This stage is particularly useful when you want to process specific documents without querying a collection.

## Syntax

```javascript
{
  $documents: [
    <document1>,
    <document2>,
    ...
  ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<document>`** | A JSON object representing a document to include in the pipeline. |

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

### Example 1: Create a pipeline from specific documents

This query demonstrates how to use the `$documents` stage to process a set of predefined documents:

```javascript
db.aggregate([{
    $documents: [{
        _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        name: "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
        location: {
            lat: 60.1441,
            lon: -141.5012
        },
        sales: {
            fullSales: 3700
        },
        tag: ["#ShopLocal", "#SeasonalSale"]
    }, {
        _id: "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
        name: "Contoso, Ltd. | Office Supply Deals - South Shana",
        location: {
            lat: 40.7128,
            lon: -74.0060
        },
        sales: {
            fullSales: 5400
        },
        tag: ["#TechDeals", "#FreeShipping"]
    }]
}, {
    $project: {
        _id: 1,
        name: 1,
        "location.lat": 1,
        "location.lon": 1,
        "sales.fullSales": 1,
        tags: "$tag"
    }
}])
```

This query returns the following results:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
        "location": {
            "lat": 60.1441,
            "lon": -141.5012
        },
        "sales": {
            "fullSales": 3700
        },
        "tags": [
            "#ShopLocal",
            "#SeasonalSale"
        ]
    },
    {
        "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
        "name": "Contoso, Ltd. | Office Supply Deals - South Shana",
        "location": {
            "lat": 40.7128,
            "lon": -74.006
        },
        "sales": {
            "fullSales": 5400
        },
        "tags": [
            "#TechDeals",
            "#FreeShipping"
        ]
    }
]
```

### Example 2: Combine `$documents` with other pipeline stages

This query combines the $documents pipeline stage along with the $match and $sort pipeline stages.

```javascript
db.aggregate([{
    $documents: [{
        _id: "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        name: "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
        location: {
            lat: 60.1441,
            lon: -141.5012
        },
        sales: {
            fullSales: 3700
        },
        tag: ["#ShopLocal", "#SeasonalSale"]
    }, {
        _id: "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
        name: "Contoso, Ltd. | Office Supply Deals - South Shana",
        location: {
            lat: 40.7128,
            lon: -74.0060
        },
        sales: {
            fullSales: 5400
        },
        tag: ["#TechDeals", "#FreeShipping"]
    }]
}, {
    $match: {
        "sales.fullSales": {
            $gt: 4000
        }
    }
}, {
    $sort: {
        "sales.fullSales": -1
    }
}])
```

This query returns the following result:

```json
[
  {
    "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
    "name": "Contoso, Ltd. | Office Supply Deals - South Shana",
    "location": { "lat": 40.7128, "lon": -74.006 },
    "sales": { "fullSales": 5400 },
    "tag": [ "#TechDeals", "#FreeShipping" ]
  }
]
```

## Limitations

- The $documents stage is only supported in database-level aggregation pipelines.
- It must be the first stage in the pipeline to function correctly.
