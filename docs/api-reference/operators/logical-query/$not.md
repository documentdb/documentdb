---
title: $not
description: The $not operator performs a logical NOT operation on a specified expression, selecting documents that don't match the expression.
type: operators
category: logical-query
---

# $not

The `$not` operator performs a logical NOT operation on a specified expression and selects documents that don't match the expression.

## Syntax

```javascript
{
    field: {
        $not: {
            < operator - expression >
        }
    }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `operator-expression` | The expression to negate |

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

### Example 1: Use NOT operation as logical-query operator

This query retrieves stores where the number of full-time staff isn't equal to 5 using the `$not` operator with $eq. It returns only the `name` and `staff` fields for up to two such matching documents.

```javascript
 db.stores.find({
     "staff.totalStaff.fullTime": {
         $not: {
             $eq: 5
         }
     }
 }, {
     "name": 1,
     "staff": 1
 }).limit(2)
```

The first two results returned by this query are:

```json
[
    {
        "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
        "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
        "staff": {
            "totalStaff": {
                "fullTime": 9,
                "partTime": 18
            }
        }
    },
    {
        "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
        "name": "Lakeshore Retail | Home Decor Hub - Franciscoton",
        "staff": {
            "totalStaff": {
                "fullTime": 7,
                "partTime": 6
            }
        }
    }
]
```

### Example 2: Use NOT operator as boolean-expression to identify stores that aren't high-volume

This query retrieves stores that don't have high sales volume (not greater than 50,000).

```javascript
db.stores.aggregate([
  {
    $project: {
      name: 1,
      totalSales: "$sales.salesByCategory.totalSales",
      isNotHighVolume: {
        $not: { $gt: ["$sales.salesByCategory.totalSales", 50000] }
      },
      storeCategory: {
        $cond: [
          { $not: { $gt: ["$sales.salesByCategory.totalSales", 50000] } },
          "High Volume Store",
          "Small/Medium Store"
        ]
      }
    }
  },
  { $limit: 2 }
])
```

The first two results returned by this query are:

```json
[
 {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "totalSales": [ 37978 ],
    "isNotHighVolume": false,
    "storeCategory": "Small/Medium Store"
  },
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "totalSales": [ 25731 ],
    "isNotHighVolume": false,
    "storeCategory": "Small/Medium Store"
  }
]
```
