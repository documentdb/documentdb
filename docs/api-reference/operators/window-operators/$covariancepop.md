---
title: $covariancePop
description: The $covariancePop operator returns the covariance of two numerical expressions
type: operators
category: window-operators
---

# $covariancePop

The `$covariancePop` operator sorts documents on one or more fields within a partition and calculates a covariance of two numerical fields within a specified document window.

## Syntax

```javascript
{
  $covariancePop: [ < numericalExpression1 > , < numericalExpression2 > ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`numericalExpression1`** | The first numerical expression to use to calculate the covariance within the specified document window|
| **`numericalExpression2`** | The first numerical expression to use to calculate the covariance within the specified document window|

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

### Example 1 - Calculate the covariance in sales volume

To get the covariance in total sales for stores in the First Up Consultants company, first run a query to filter on the company name, then sort the resulting documents in ascending order of the last updated timestamp, and calculate the covariance between the first and current document in the sorted result set.

```javascript
db.stores.aggregate(
    [{
            "$match": {
                "company": {
                    "$in": [
                        "First Up Consultants"
                    ]
                }
            }
        },
        {
            "$setWindowFields": {
                "partitionBy": "$company",
                "sortBy": {
                    "lastUpdated": 1
                },
                "output": {
                    "covariancePopForSales": {
                        "$covariancePop": [{
                                "$hour": "$lastUpdated"
                            },
                            "$sales.totalSales"
                        ],
                        "window": {
                            "documents": [
                                "unbounded",
                                "current"
                            ]
                        }
                    }
                }
            }
        },
        {
            "$project": {
                "company": 1,
                "name": 1,
                "sales.totalSales": 1,
                "lastUpdated": 1,
                "covariancePopForSales": 1
            }
        }
    ]
)
```

The first two results returned by this query are:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "sales": {},
        "company": "First Up Consultants",
        "lastUpdated": "2025-06-11T10:48:01.291Z",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "covariancePopForSales": null
    },
    {
        "_id": "8e7a259b-f7d6-4ec5-a521-3bed53adc587",
        "name": "First Up Consultants | Drone Stop - Lake Joana",
        "sales": {},
        "company": "First Up Consultants",
        "lastUpdated": {
            "t": 1727827539,
            "i": 1
        },
        "covariancePopForSales": null
    }
]
```
