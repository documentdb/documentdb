---
title: $indexStats
description: The $indexStats stage returns usage statistics for each index in the collection.
type: operators
category: aggregation
---

# $indexStats

The `$indexStats` aggregation stage returns usage statistics for each index in the collection. This stage is useful for analyzing index performance, identifying unused indexes, and optimizing query performance.

## Syntax

```javascript
{
  $indexStats: {}
}
```

## Parameters

The `$indexStats` stage takes no parameters.

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

### Example 1 - Fetch index statistics

This query retrieves usage statistics for all indexes on the stores collection.

```javascript
db.stores.aggregate([
  { $indexStats: {} }
])
```

The query returns statistics for each index including access patterns and usage frequency.

```json
[
  {
    "name": "_id_",
    "key": { "_id": 1 },
    "accesses": { "ops": 41675, "since": "2025-06-07T13:51:41.231Z" },
    "spec": { "v": 2, "key": { "_id": 1 }, "name": "_id_" }
  },
  {
    "name": "location_2dsphere",
    "key": { "location": "2dsphere" },
    "accesses": { "ops": 0, "since": "2025-06-07T13:51:41.231Z" },
    "spec": {
      "v": 2,
      "key": { "location": "2dsphere" },
      "name": "location_2dsphere",
      "2dsphereIndexVersion": 3
    }
  },
  {
    "name": "name_text_sales.salesByCategory.categoryName_text_promotionEvents.eventName_text_promotionEvents.discounts.categoryName_text",
    "key": {
      "name": "text",
      "sales.salesByCategory.categoryName": "text",
      "promotionEvents.eventName": "text",
      "promotionEvents.discounts.categoryName": "text"
    },
    "accesses": { "ops": 8, "since": "2025-06-07T13:51:41.231Z" },
    "spec": {
      "v": 2,
      "key": {
        "name": "text",
        "sales.salesByCategory.categoryName": "text",
        "promotionEvents.eventName": "text",
        "promotionEvents.discounts.categoryName": "text"
      },
      "name": "name_text_sales.salesByCategory.categoryName_text_promotionEvents.eventName_text_promotionEvents.discounts.categoryName_text"
    }
  }
]
```
