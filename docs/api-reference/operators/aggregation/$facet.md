---
title: $facet
description: The $facet allows for multiple parallel aggregations to be executed within a single pipeline stage.
type: operators
category: aggregation
---

# $facet

The `$facet` stage aggregation pipelines allow for multiple parallel aggregations to be executed within a single pipeline stage. It's useful for performing multiple analyses on the same dataset in a single query.

## Syntax

```javascript
{
  "$facet": {
    "outputField1": [ { "stage1": {} }, { "stage2": {} } ],
    "outputField2": [ { "stage1": {} }, { "stage2": {} } ]
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`outputFieldN`**| The name of the output field.|
| **`stageN`**| The aggregation stage to be executed.|

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

### Example 1: Faceted search on sales and promotions

To perform simultaneous analyses on sales and promotions, for specified product categories. The `salesAnalysis` pipeline unwinds the `salesByCategory`, filters for certain categories, and groups them to sum `totalSales`. The promotion analysis pipeline unwinds promotional events and their discounts, filters for specific categories like `Laptops`, `Smartphones` etc., and groups them to calculate the average discount percentage. The input documents from `stores` collection are fetched from the database only once, at the beginning of this operation.

```javascript
db.stores.aggregate([
  {
    $facet: {
      salesAnalysis: [
        { $unwind: "$sales.salesByCategory" },
        { $match: { "sales.salesByCategory.categoryName": { $in: ["Laptops", "Smartphones", "Cameras", "Watches"] } } },
        { $group: { _id: "$sales.salesByCategory.categoryName", totalSales: { $sum: "$sales.salesByCategory.totalSales" } } }
      ],
      promotionAnalysis: [
        { $unwind: "$promotionEvents" },
        { $unwind: "$promotionEvents.discounts" },
        { $match: { "promotionEvents.discounts.categoryName": { $in: ["Laptops", "Smartphones", "Cameras", "Watches"] } } },
        { $group: { _id: "$promotionEvents.discounts.categoryName", avgDiscount: { $avg: "$promotionEvents.discounts.discountPercentage" } } }
      ]
    }
  }
]).pretty()
```

This query returns the following result:

```json
[
  {
    "salesAnalysis": [
      { "_id": "Smartphones", "totalSales": 440815 },
      { "_id": "Laptops", "totalSales": 679453 },
      { "_id": "Cameras", "totalSales": 481171 },
      { "_id": "Watches", "totalSales": 492299 }
    ],
    "promotionAnalysis": [
      { "_id": "Smartphones", "avgDiscount": 14.32 },
      { "_id": "Laptops", "avgDiscount": 14.780645161290323 },
      { "_id": "Cameras", "avgDiscount": 15.512195121951219 },
      { "_id": "Watches", "avgDiscount": 15.174418604651162 }
    ]
  }
]
```
