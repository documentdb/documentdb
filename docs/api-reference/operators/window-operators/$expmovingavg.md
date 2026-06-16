---
title: $expMovingAvg
description: The $expMovingAvg operator calculates the moving average of a field based on the specified number of documents to hold the highest weight
type: operators
category: window-operators
---

# $expMovingAvg

The `$expMovingAvg` operator calculates the exponential moving average of the values of a specified field.

## Syntax

```javascript
{
    $expMovingAvg: {
        input: < field to use for calculation >,
        N: < number of recent documents with the highest weight
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The field whose values are used to calculate the exponential moving average|
| **`N`** | The number of previous documents with the highest weight in calculating the exponential moving average|

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

### Example 1 - Calculate the exponential moving average of total sales

To retrieve the exponential moving average of the total sales across all stores within the First Up Consultants company, first run a query to filter on the company. Then, sort the resulting documents in ascending order of their opening date. Finally, assigned the highest weight to the two most recent documents to calculate the exponential moving average of total sales.

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
            "storeOpeningDate": 1
        },
        "output": {
            "expMovingAvgForSales": {
                "$expMovingAvg": {
                    "input": "$sales.totalSales",
						        "N": 2
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
        "storeOpeningDate": 1,
        "expMovingAvgForSales": 1
    }
  }])
```

The firs two results returned by this query are:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "sales": {
            "revenue": 37701
        },
        "company": "First Up Consultants",
        "storeOpeningDate": {
            "$date": 1633219200000
        },
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "expMovingAvgForSales": 37701
    },
    {
        "_id": "8e7a259b-f7d6-4ec5-a521-3bed53adc587",
        "name": "First Up Consultants | Drone Stop - Lake Joana",
        "sales": {
            "revenue": 14329
        },
        "company": "First Up Consultants",
        "storeOpeningDate": {
            "$date": 1706958339311
        },
        "expMovingAvgForSales": 22119.666666666668
    }
]
```

### Example 2 - Calculate the exponential moving average of the total sales using the alpha parameter

To retrieve the exponential moving average of the total sales across all stores within the First Up Consultants company, first run a query to filter on the company. Then, sort the resulting documents in ascending order of their opening date. Finally, specify a decay rate (alpha) to calculate the exponential moving average of total sales. A higher alpha value gives previous documents a lower weight in the calculation.

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
                "storeOpeningDate": 1
            },
            "output": {
                "expMovingAvgForSales": {
                    "$expMovingAvg": {
                        "input": "$sales.totalSales",
                        "alpha": 0.75
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
            "storeOpeningDate": 1,
            "expMovingAvgForSales": 1
        }
    }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "sales": {
            "revenue": 37701
        },
        "company": "First Up Consultants",
        "storeOpeningDate": "2021-10-03T00:00:00.000Z",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "expMovingAvgForSales": 37701
    },
    {
        "_id": "8e7a259b-f7d6-4ec5-a521-3bed53adc587",
        "name": "First Up Consultants | Drone Stop - Lake Joana",
        "sales": {
            "revenue": 14329
        },
        "company": "First Up Consultants",
        "storeOpeningDate": "2024-09-02T00:05:39.311Z",
        "expMovingAvgForSales": 20172
    }
]
```
