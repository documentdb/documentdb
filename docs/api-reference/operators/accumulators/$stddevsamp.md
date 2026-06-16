---
title: $stddevsamp
description: The $stddevsamp operator calculates the standard deviation of a specified sample of values and not the entire population
type: operators
category: accumulators
---

# $stddevsamp

The `$stddevsamp` operator calculates the standard deviation by taking a specified sample of the values of a field. The standard deviation is calculated by taking a random sample of the specified size. If a precise standard deviation is needed, $stdDevPop must be used instead.

## Syntax

```javascript
{
  $stddevsamp: {fieldName}
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`fieldName`** | The field whose values are used to calculate the standard deviation of the specified sample size|

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

This query calculates the standard deviation of total sales across stores in the "Fourth Coffee" company by taking a random sample of 10 documents matching the filtering criteria.

```javascript
db.stores.aggregate([{
    $match: {
        "company": "Fourth Coffee"
    }
}, {
    $sample: {
        size: 10
    }
}, {
    $group: {
        _id: "$company",
        stdDev: {
            $stdDevSamp: "$sales.totalSales"
        }
    }
}])
```

This query returns the following result:

```json
[
  {
      "_id": "Fourth Coffee",
      "stdDev": 22040.044055209048
  }
]
```
