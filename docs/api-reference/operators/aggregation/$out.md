---
title: $out
description: The `$out` stage in an aggregation pipeline writes the resulting documents to a specified collection.
type: operators
category: aggregation
---

# $out

The `$out` stage in an aggregation pipeline allows you to write the resulting documents of the pipeline into a specified collection. It is commonly used to save the output of complex aggregation operations for further use or analysis. When used, the specified collection is either created or replaced with the new documents.

## Syntax

```javascript
{
  $out: "<outputCollection>"
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<outputCollection>`** | The name of the collection where the aggregation result will be stored. |

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

### Example 1:Writing aggregation results to a new collection

This query writes stores with total sales greater than 30,000 into a new collection called `highSales`.

```javascript
db.stores.aggregate([
  {
    $match: {
      "sales.salesByCategory.totalSales": { $gt: 30000 }
    }
  },
  {
    $out: "highSales"
  }
])
```

### Example 2: Writing processed data to another collection

This query extracts promotion events and writes them into a collection named `promotionEventsSummary`.

```javascript
db.stores.aggregate([
  {
    $project: {
      eventName: 1,
      promotionalDates: 1,
      "discounts.categoryName": 1,
      "discounts.discountPercentage": 1
    }
  },
  {
    $out: "promotionEventsSummary"
  }
])
```
