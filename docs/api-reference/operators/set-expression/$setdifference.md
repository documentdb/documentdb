---
title: $setDifference
description: The $setDifference operator returns a set with elements that exist in one set but not in a second set.
type: operators
category: set-expression
---

# $setDifference

The `$setDifference` operator returns a set that includes elements that exist in one set but not in another set. It treats arrays as sets and ignores duplicate values and element order.

## Syntax

```javascript
{
  $setDifference: [ <array1>, <array2> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| `array1` | The first array to compare. Elements unique to this array are returned. |
| `array2` | The second array to compare against the first array. Elements that exist in both arrays are excluded from the result. |

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

### Example 1: Find categories of products for sale but not discounted

This query retrieves product categories that include sales data but no discounts.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      soldCategories: "$sales.salesByCategory.categoryName",
      discountedCategories: {
        $reduce: {
          input: "$promotionEvents",
          initialValue: [],
          in: {
            $concatArrays: ["$$value", "$$this.discounts.categoryName"]
          }
        }
      }
    }
  },
  {
    $project: {
      name: 1,
      soldCategories: 1,
      discountedCategories: 1,
      categoriesWithoutDiscounts: {
        $setDifference: ["$soldCategories", "$discountedCategories"]
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
    "soldCategories": [
      "Sound Bars",
      "Game Controllers",
      "Remote Controls",
      "VR Games"
    ],
    "discountedCategories": [
      "DVD Players",
      "Projector Lamps",
      "Media Players",
      "Blu-ray Players",
      "Home Theater Systems",
      "Televisions"
    ],
    "categoriesWithoutDiscounts": [
      "Sound Bars",
      "Home Theater Projectors",
      "Game Controllers",
      "Remote Controls",
      "VR Games"
    ]
  }
]
```

### Example 2: Compare staff distribution types

This query finds the difference between two hypothetical staff requirement lists.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      requiredSkills: ["Sales", "Customer Service", "Technical Support", "Inventory Management"],
      availableSkills: ["Sales", "Customer Service", "Marketing", "Administration"],
      missingSkills: {
        $setDifference: [
          ["Sales", "Customer Service", "Technical Support", "Inventory Management"],
          ["Sales", "Customer Service", "Marketing", "Administration"]
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
    "requiredSkills": [
      "Sales",
      "Customer Service", 
      "Technical Support",
      "Inventory Management"
    ],
    "availableSkills": [
      "Sales",
      "Customer Service",
      "Marketing",
      "Administration"
    ],
    "missingSkills": [
      "Technical Support",
      "Inventory Management"
    ]
  }
]
```
