---
title: $collStats
description: The $collStats stage in the aggregation pipeline is used to return statistics about a collection.
type: operators
category: aggregation
---

# $collStats

The $collStats stage in the aggregation pipeline is used to return statistics about a collection. This stage can be particularly useful for understanding the performance characteristics of a collection, such as the number of documents, the size of the collection, and storage statistics. It provides detailed information that can help with database optimization and monitoring.

## Syntax

```javascript
{
  $collStats: {
    latencyStats: { histograms: <boolean> },
    storageStats: { scale: <number> },
    count: {}
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`latencyStats`** | Optional. Specifies whether to include latency statistics. The `histograms` field is a boolean that indicates whether to include histograms of latency data. |
| **`storageStats`** | Optional. Specifies whether to include storage statistics. The `scale` field is a number that indicates the scale factor for the storage statistics. |
| **`count`** | Optional. Includes the count of documents in the collection. |

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

### Example: Basic collection statistics

This query counts all the documents in the stores collection.

```javascript
db.stores.aggregate([
  {
    $collStats: {
      count: {}
    }
  }
])
```

This query returns the following result:

```json
[
  { "ns": "StoreData.stores", "count": 41505 }
]
```
