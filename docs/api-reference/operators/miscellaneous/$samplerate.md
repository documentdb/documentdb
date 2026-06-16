---
title: $sampleRate
description: The $sampleRate operator randomly samples documents from a collection based on a specified probability rate, useful for statistical analysis and testing.
type: operators
category: miscellaneous
---

# $sampleRate

The `$sampleRate` operator randomly samples documents from a collection based on a specified probability rate. This operator is useful for statistical analysis, testing with subset data, and performance optimization when working with large datasets where you need a representative sample.

## Syntax

```javascript
{
  $match: {
    $sampleRate: <number>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`number`** | A floating-point number between 0 and 1 representing the probability that a document will be included in the sample. For example, 0.33 means approximately 33% of documents are sampled.

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

### Example 1: Basic random sampling

This query returns one-third of all documents in the stores collection, selected randomly.

```javascript
db.stores.aggregate([{
    $match: {
        $sampleRate: 0.33
    }
}])
```

### Example 2: Sampling with more filters

This query first filters stores with sales above 50,000, then randomly samples 50% of those matching documents.

```javascript
db.stores.aggregate([
  { $match: { 
    "sales.totalSales": { $gt: 50000 },
    $sampleRate: 0.5 
  }}
])
```

### Example 3: Sampling for statistical analysis

This query samples 25% of stores and calculates statistical measures on the sampled data.

```javascript
db.stores.aggregate([
  { $match: { $sampleRate: 0.25 } },
  { $group: {
    _id: null,
    averageSales: { $avg: "$sales.totalSales" },
    totalStores: { $sum: 1 },
    maxSales: { $max: "$sales.totalSales" },
    minSales: { $min: "$sales.totalSales" }
  }}
])
```

The $sampleRate operator is valuable for statistical analysis and data exploration when working with large datasets where processing all documents would be computationally expensive. It efficiently creates representative samples for performance testing, quality assurance validation, and machine learning dataset generation. The operator is ideal for approximate reporting scenarios where statistical accuracy is acceptable and processing speed is prioritized over exact precision.
