---
title: $setIntersection
description: The $setIntersection operator returns the common elements that appear in all input arrays.
type: operators
category: set-expression
---

# $setIntersection

The `$setIntersection` operator returns an array that contains elements that appear in all of the input arrays. It treats arrays as sets, which means that it removes duplicates and ignores the order of elements.

## Syntax

```javascript
{
  $setIntersection: [ <array1>, <array2>, ... ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `<array1>, <array2>, ...` | Two or more arrays to find the intersection of. Each array is treated as a set. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
  "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
  "location": {
    "lat": 70.1272,
    "lon": 69.7296
  },
  "staff": {
    "totalStaff": {
      "fullTime": 19,
      "partTime": 20
    }
  },
  "sales": {
    "totalSales": 151864,
    "salesByCategory": [
      {
        "categoryName": "Sound Bars",
        "totalSales": 2120
      },
      {
        "categoryName": "Home Theater Projectors",
        "totalSales": 45004
      },
      {
        "categoryName": "Game Controllers",
        "totalSales": 43522
      },
      {
        "categoryName": "Remote Controls",
        "totalSales": 28946
      },
      {
        "categoryName": "VR Games",
        "totalSales": 32272
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Massive Markdown Mania",
      "promotionalDates": {
        "startDate": {
          "Year": 2023,
          "Month": 6,
          "Day": 29
        },
        "endDate": {
          "Year": 2023,
          "Month": 7,
          "Day": 9
        }
      },
      "discounts": [
        {
          "categoryName": "DVD Players",
          "discountPercentage": 14
        },
        {
          "categoryName": "Projector Lamps",
          "discountPercentage": 6
        },
        {
          "categoryName": "Media Players",
          "discountPercentage": 21
        },
        {
          "categoryName": "Blu-ray Players",
          "discountPercentage": 21
        },
        {
          "categoryName": "Home Theater Systems",
          "discountPercentage": 5
        },
        {
          "categoryName": "Televisions",
          "discountPercentage": 22
        }
      ]
    },
    {
      "eventName": "Discount Delight Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2023,
          "Month": 12,
          "Day": 26
        },
        "endDate": {
          "Year": 2024,
          "Month": 1,
          "Day": 5
        }
      },
      "discounts": [
        {
          "categoryName": "Game Controllers",
          "discountPercentage": 22
        },
        {
          "categoryName": "Home Theater Projectors",
          "discountPercentage": 23
        },
        {
          "categoryName": "Sound Bars",
          "discountPercentage": 10
        },
        {
          "categoryName": "Media Players",
          "discountPercentage": 10
        },
        {
          "categoryName": "Televisions",
          "discountPercentage": 9
        },
        {
          "categoryName": "Projector Lamps",
          "discountPercentage": 24
        }
      ]
    }
  ]
}
```

### Example 1: Find common categories between sales and promotions

This query determines which product categories appear in a store's sales data and promotion discounts.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      salesCategories: "$sales.salesByCategory.categoryName",
      firstPromotionCategories: { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
      secondPromotionCategories: { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 1] },
      commonSalesAndFirstPromotion: {
        $setIntersection: [
          "$sales.salesByCategory.categoryName",
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] }
        ]
      },
      commonSalesAndSecondPromotion: {
        $setIntersection: [
          "$sales.salesByCategory.categoryName",
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 1] }
        ]
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "salesCategories": [
      "Sound Bars",
      "Game Controllers",
      "Remote Controls",
      "VR Games"
    ],
    "firstPromotionCategories": [
      "DVD Players",
      "Projector Lamps",
      "Media Players",
      "Blu-ray Players",
      "Home Theater Systems",
      "Televisions"
    ],
    "secondPromotionCategories": [
      "TV Mounts",
      "Game Accessories",
      "Portable Projectors",
      "Projector Screens",
      "Blu-ray Players",
      "DVD Players"
    ],
    "commonSalesAndFirstPromotion": [],
    "commonSalesAndSecondPromotion": []
  }
]
```

### Example 2: Find common categories across multiple promotion events

This query fetches categories that appear in multiple promotion events.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      commonAcrossPromotions: {
        $setIntersection: [
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 1] },
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 2] }
        ]
      }
    }
  }
])
```

This query returns the following result.

```json
[
   {
      "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
      "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
      "commonAcrossPromotions": []
   }
]
```
