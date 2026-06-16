---
title: $stddevpop
description: The $stddevpop operator calculates the standard deviation of the specified values
type: operators
category: accumulators
---

# $stddevpop

The `$stddevpop` operator calculates the standard deviation of the specified values. The operator can only calculate the standard deviation of numeric values.

## Syntax

```javascript
{
  $stddevpop: {fieldName}
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`fieldName`** | The field whose values are used to calculate the standard deviation|

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

### Example 1 - Calculate the standard deviation of total sales

To calculate the standard deviation of the total sales across all sales categories for stores belonging to "Fourth Coffee", first filter on the company field, then calculate the total sales across all resulting stores using stddevpop and return the aggregated result.

```javascript
db.stores.aggregate([{
    $match: {
        company: "Fourth Coffee"
    }
}, {
    $group: {
        _id: "$company",
        stdDev: {
            $stdDevPop: "$sales.totalSales"
        }
    }
}])[{
    _id: 'Fourth Coffee',
    stdDev: 0
}]
```

This query returns the following result:

```json
[
  {
      "_id": "Fourth Coffee",
      "stdDev": 39133.27057120701
  }
]
```

### Example 2 - Calculate the standard deviation of a field with a single value

To calculate the standard deviation of a field with only one distinct value, the standard deviation is 0. This query groups documents corresponding to the "Fourth Company". Each store contains a single document and only one distinct value for total sales.

```javascript
db.stores.aggregate([{
    $match: {
        company: "Fourth Coffee"
    }
}, {
    $group: {
        _id: "$name",
        stdDev: {
            $stdDevPop: "$sales.totalSales"
        }
    }
}])
```

This query returns the following results:

```json
[
  {
      "_id": "Fourth Coffee | Outdoor Equipment Collection - Kochview",
      "stdDev": 0
  },
  {
      "_id": "Fourth Coffee | Grocery Hub - Brakusborough",
      "stdDev": 0
  },
  {
      "_id": "Fourth Coffee | Pet Supply Nook - Lake Armanimouth",
      "stdDev": 0
  },
  {
      "_id": "Fourth Coffee | Beauty Product Nook - Emmytown",
      "stdDev": 0
  },
  {
      "_id": "Fourth Coffee | Bed and Bath Closet - Legroston",
      "stdDev": 0
  },
  {
      "_id": "Fourth Coffee | Automotive Part Collection - Cassinport",
      "stdDev": 0
  }
]
```

### Example 3 - Calculate the standard deviation for a field when using window operators

This query calculates the standard deviation of total sales for stores belonging to the "First Up Consultants" company from the first to the current document in the result set.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        },
        $and: [{
            lastUpdated: {
                $gt: ISODate("2024-09-01T03:06:24.180Z")
            }
        }, {
            lastUpdated: {
                "$lt": ISODate("2025-09-30T03:55:17.557Z")
            }
        }]
    }
}, {
    $setWindowFields: {
        partitionBy: "$company",
        sortBy: {
            lastUpdated: 1
        },
        output: {
            stdDevPopTotalSales: {
                $stdDevPop: "$sales.totalSales",
                window: {
                    documents: ["unbounded", "current"]
                }
            }
        }
    }
}, {
    $project: {
        company: 1,
        name: 1,
        "sales.totalSales": 1,
        lastUpdated: 1,
        stdDevPopTotalSales: 1
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "sales": {},
        "company": "First Up Consultants",
        "lastUpdated": {
            "$date": "2025-06-11T10:48:01.291Z"
        },
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "stdDevPopTotalSales": null
    }
]
```
