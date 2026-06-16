---
title: $round
description: The $round operator rounds a number to a specified decimal place.
type: operators
category: arithmetic-expression
---

# $round

The `$round` operator is used to round a number to a specified decimal place. It's useful in aggregations where numerical precision is important, such as financial calculations or statistical analysis.

## Syntax

```javascript
{
  $round: [ <number>, <place> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<number>`** | The number to be rounded. |
| **`<place>`** | The decimal place to which the number should be rounded. |

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

### Example 1 - Round the location coordinates of stores

To round the latitude and longitude of all stores within the "First Up Consultants" company, first run a query to filter on the name of the company. Then, use the $round operator on the lat and lon fields to return the desired result.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $project: {
        company: 1,
        "location.lat": 1,
        "location.lon": 1,
        roundedLat: {
            $round: ["$location.lat", 1]
        },
        roundedLon: {
            $round: ["$location.lon", 1]
        }
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "location": {
            "lat": 87.2239,
            "lon": -129.0506
        },
        "company": "First Up Consultants",
        "roundedLat": 87.2,
        "roundedLon": -129.1
    },
    {
        "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
        "location": {
            "lat": -29.1866,
            "lon": -112.7858
        },
        "company": "First Up Consultants",
        "roundedLat": -29.2,
        "roundedLon": -112.8
    },
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "location": {
            "lat": -0.2136,
            "lon": 108.7466
        },
        "company": "First Up Consultants",
        "roundedLat": -0.2,
        "roundedLon": 108.7
    }
]
```

### Example 2 - Round to the nearest thousand

To round the total sales volume of stores within the "First Up Consultants" company, first run a query to filter stores by the company name. Then use the $round operator on the totalSales field to round the value to the nearest thousand.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $project: {
        company: 1,
        "sales.totalSales": 1,
        roundedSales: {
            $round: ["$sales.totalSales", -3]
        }
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "sales": {},
        "company": "First Up Consultants",
        "roundedSales": 279000
    },
    {
        "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
        "sales": {},
        "company": "First Up Consultants",
        "roundedSales": 50000
    },
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "sales": {},
        "company": "First Up Consultants",
        "roundedSales": 69000
    }
]
```
