---
title: $covarianceSamp
description: The $covarianceSamp operator returns the covariance of a sample of two numerical expressions
type: operators
category: window-operators
---

# $covarianceSamp

The `$covarianceSamp` operator sorts documents on one or more fields within a partition and calculates the covariance of a sample two numerical fields within a specified document window.

## Syntax

```javascript
{
    $covarianceSamp: [ < numericalExpression1 > , < numericalExpression2 > ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`numericalExpression1`** | The first numerical expression to use to calculate the covariance sample within the specified document window|
| **`numericalExpression2`** | The first numerical expression to use to calculate the covariance sample within the specified document window|

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

### Example 1 - Calculate the covariance sample between an unbounded starting document and the current document

To calculate the covariance sample for stores in the First Up Consultants company, first run a query to filter on the company, then sort the resulting stores in ascending order of their opening dates, and calculate the covariance of the sales of the sorted result set.

```javascript
db.stores.aggregate(
[{
      "$match": {
          "company": {
              "$in": [
                  "First Up Consultants"
              ]
          },
        "$and": [
            {
                "storeOpeningDate": {
                    "$gt": ISODate("2024-09-01T03:06:24.180Z")
                }
            },
            {
                "storeOpeningDate": {
                    "$lt": ISODate("2025-09-30T03:55:17.557Z")
                }
            }
        ]
      }
  },
  {
    "$setWindowFields": {
        "partitionBy": "$company",
        "sortBy": {
            "storeOpeningDate": 1
        },
        "output": {
            "covarianceSampForSales": {
                "$covarianceSamp": [
                    {
                        "$hour": "$storeOpeningDate"
                    },
                    "$sales.revenue"
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
        "sales.revenue": 1,
        "storeOpeningDate": 1,
        "covarianceSampForSales": 1
    }
  }]
)
```

The first two results returned by this query are:

```json
[
    {
        "_id": "2d315043-db26-4d18-8bb7-71ba922f00a0",
        "name": "First Up Consultants | Furniture Shoppe - Wymantown",
        "sales": {
            "revenue": 38042
        },
        "company": "First Up Consultants",
        "storeOpeningDate": "2024-09-02T02:00:52.592Z",
        "covarianceSampForSales": 935.0972222222222
    },
    {
        "_id": "416adb8c-7d65-40e5-af88-8659c71194ce",
        "name": "First Up Consultants | Picture Frame Bazaar - South Lysanneborough",
        "sales": {
            "revenue": 37157
        },
        "company": "First Up Consultants",
        "storeOpeningDate": "2024-09-02T02:39:50.269Z",
        "covarianceSampForSales": 1901.1777777777777
    }
]
```
