---
title: $literal
description: The $literal operator returns the specified value without parsing it as an expression, allowing literal values to be used in aggregation pipelines.
type: operators
category: literal-expression
---

# $literal

The `$literal` operator returns the specified value without parsing it as an expression. This operator is useful when you need to include literal values that might otherwise be interpreted as field names, operators, or expressions in your aggregation pipeline. It ensures that the value is treated as a constant rather than being evaluated.

## Syntax

```javascript
{
  $literal: <value>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<value>`** | Any value that should be returned as-is without interpretation. This can be a string, number, boolean, array, object, or null. |

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

### Example 1: Adding literal status fields

This query demonstrates adding literal status information to store documents, including literal strings that might otherwise be interpreted as field names or operators.

```javascript
db.stores.aggregate([
  { $match: {"_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f"} },
  {
    $project: {
      name: 1,
      totalSales: "$sales.salesByCategory.totalSales",
      status: { $literal: "Active" },
      reviewStatus: { $literal: "$pending" },
      priority: { $literal: 1 },
      metadata: {
        $literal: {
          lastUpdated: "2024-06-13",
          source: "automated-system"
        }
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
    "totalSales": 37701,
    "status": "Active",
    "reviewStatus": "$pending",
    "priority": 1,
    "metadata": {
      "lastUpdated": "2024-06-13",
      "source": "automated-system"
    }
  }
]
```

### Example 2: Creating literal arrays and conditional values

This query shows how to use `$literal` with arrays and in conditional expressions to ensure values are not interpreted as operators.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      totalSales: "$sales.salesByCategory.totalSales",
      performanceCategory: {
        $cond: {
          if: { $gte: ["$sales.totalSales", 100000] },
          then: { $literal: "High Performer" },
          else: { $literal: "Standard" }
        }
      },
      tags: { $literal: ["$featured", "$promoted", "$new"] },
      searchKeywords: {
        $literal: {
          "$or": ["electronics", "entertainment"],
          "$and": ["home", "theater"]
        }
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
    "totalSales": 160000,
    "performanceCategory": "High Performer",
    "tags": ["$featured", "$promoted", "$new"],
    "searchKeywords": {
      "$or": ["electronics", "entertainment"],
      "$and": ["home", "theater"]
    }
  }
]
```

### Example 3: Literal null and boolean values

This query demonstrates using `$literal` with null values and booleans, especially useful when these values need to be explicitly set rather than computed.

```javascript
db.stores.aggregate([
  { $match: {"_id": "e6895a31-a5cd-4103-8889-3b95a864e5a6"} },
  {
    $project: {
      name: 1,
      totalSales: "$sales.salesByCategory.totalSales",
      specialOffer: { $literal: null },
      isOnline: { $literal: false },
      hasInventory: { $literal: true },
      calculationFormula: { $literal: "$multiply: [price, quantity]" },
      ratingSystem: {
        $literal: {
          min: 0,
          max: 5,
          default: null
        }
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "e6895a31-a5cd-4103-8889-3b95a864e5a6",
    "name": "VanArsdel, Ltd. | Picture Frame Store - Port Clevelandton",
    "totalSales": 17676,
    "specialOffer": null,
    "isOnline": false,
    "hasInventory": true,
    "calculationFormula": "$multiply: [price, quantity]",
    "ratingSystem": {
      "min": 0,
      "max": 5,
      "default": null
    }
  }
]
```
