---
title: $integral
description: The $integral operator calculates the area under a curve with the specified range of documents forming the adjacent documents for the calculation.
type: operators
category: window-operators
---

# $integral

The `$integral` operator calculates the area under a curve based on the specified range of documents sorted based on a specific field.

## Syntax

```javascript
{
    $integral: {
        input: < expression > ,
        unit: < time window >
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | The field in the documents for the integral|
| **`unit`** | The specified time unit for the integral|

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

### Example 1 - Calculate the integral of total sales

To calculate the integral of total sales across all stores under the First Up Consultants company, first run a query to filter on the company name. Then, sort the resulting stores in ascending order of their opening dates. Lastly, calculate the integral of total sales from the first to the current document in the sorted result set.

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
            "salesIntegral": {
                "$integral": {
                        "input": "$sales.revenue",
			"unit": "hour"
                },
                "window": {
                    "range": [
                        "unbounded",
                        "current"
                    ],
					        "unit": "hour"
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
        "salesIntegral": 1
    }
  }])
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
        "salesIntegral": 0
    },
    {
        "_id": "8e7a259b-f7d6-4ec5-a521-3bed53adc587",
        "name": "First Up Consultants | Drone Stop - Lake Joana",
        "sales": {
            "revenue": 14329
        },
        "company": "First Up Consultants",
        "storeOpeningDate": "2024-09-02T00:05:39.311Z",
        "salesIntegral": 664945851.9932402
    }
]
```
