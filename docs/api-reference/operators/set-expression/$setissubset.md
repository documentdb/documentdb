---
title: $setIsSubset
description: The $setIsSubset operator determines if one array is a subset of a second array.
type: operators
category: set-expression
---

# $setIsSubset

The `$setIsSubset` operator returns a Boolean value that indicates if one array is a subset of a second array. It treats arrays as sets, which means it ignores duplicates and element order. It returns `true` if all the elements in the first array exist in the second array. Otherwise, it returns `false`.

## Syntax

```javascript
{
  $setIsSubset: [ <array1>, <array2> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `<array1>` | The array to check to see if it's a subset of `<array2>`. |
| `<array2>` | The array to check against. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
  "name": "First Up Consultants | Bed and Bath Center - South Amir",
  "location": {
    "lat": 60.7954,
    "lon": -142.0012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 18,
      "partTime": 17
    }
  },
  "sales": {
    "totalSales": 37701,
    "salesByCategory": [
      {
        "categoryName": "Mattress Toppers",
        "totalSales": 37701
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Price Drop Palooza",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 21
        },
        "endDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 30
        }
      },
      "discounts": [
        {
          "categoryName": "Bath Accessories",
          "discountPercentage": 18
        },
        {
          "categoryName": "Pillow Top Mattresses",
          "discountPercentage": 17
        },
        {
          "categoryName": "Bathroom Scales",
          "discountPercentage": 9
        },
        {
          "categoryName": "Towels",
          "discountPercentage": 5
        },
        {
          "categoryName": "Bathrobes",
          "discountPercentage": 5
        },
        {
          "categoryName": "Mattress Toppers",
          "discountPercentage": 6
        },
        {
          "categoryName": "Hand Towels",
          "discountPercentage": 9
        },
        {
          "categoryName": "Shower Heads",
          "discountPercentage": 5
        },
        {
          "categoryName": "Bedspreads",
          "discountPercentage": 19
        },
        {
          "categoryName": "Bath Mats",
          "discountPercentage": 21
        }
      ]
    }
  ]
}
```

### Example 1: Determine if sales categories are a subset of promotion categories

This query determines if all of a store's categories are included in their promotion discounts, and vice versa. This query returns categories included under both the sales and promotion brackets. It confirms that the `sales` value is a subset of a particular promotion category (but doesn't do the reverse).

```javascript
db.stores.aggregate([
  { $match: {"_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f"} },
  {
    $project: {
      name: 1,
      salesCategories: "$sales.salesByCategory.categoryName",
      promotionCategories: { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
      salesAreSubsetOfPromotions: {
        $setIsSubset: [
          "$sales.salesByCategory.categoryName",
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] }
        ]
      },
      promotionsAreSubsetOfSales: {
        $setIsSubset: [
          { $arrayElemAt: ["$promotionEvents.discounts.categoryName", 0] },
          "$sales.salesByCategory.categoryName"
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
    "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
    "name": "First Up Consultants | Bed and Bath Center - South Amir",
    "salesCategories": [
      "Mattress Toppers"
    ],
    "promotionCategories": [
      "Bath Accessories",
      "Pillow Top Mattresses",
      "Bathroom Scales",
      "Towels",
      "Bathrobes",
      "Mattress Toppers",
      "Hand Towels",
      "Shower Heads",
      "Bedspreads",
      "Bath Mats"
    ],
    "salesAreSubsetOfPromotions": true,
    "promotionsAreSubsetOfSales": false
  }
]
```
