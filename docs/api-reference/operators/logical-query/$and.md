---
title: $and
description: The $and operator joins multiple query clauses and returns documents that match all specified conditions.
type: operators
category: logical-query
---

# $and

The `$and` operator performs a logical AND operation on an array of expressions and retrieves documents that satisfy all the expressions.

## Syntax

```javascript
{
    $and: [{
        < expression1 >
    }, {
        < expression2 >
    }, ..., {
        < expressionN >
    }]
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `expression` | An array of expressions that must all be true for a document to be included in the results |

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

### Example 1: Use AND operator as logical-query

This query filters for stores where the number of full-time employees is greater than 10 and part-time employees is less than 15 using the `$and` operator. It projects only the `name` and `staff` fields and limits the result to three records.

```javascript
db.stores.find({
    $and: [{
        "staff.employeeCount.fullTime": {
            $gt: 10
        }
    }, {
        "staff.employeeCount.partTime": {
            $lt: 15
        }
    }]
}, {
    "name": 1,
    "staff": 1
}).limit(3)
```

The first three results returned by this query are:

```json
[
    {
        "_id": "e60c807b-d31c-4903-befb-5d608f260ba3",
        "name": "Wide World Importers | Appliance Emporium - Craigfort",
        "staff": {
            "totalStaff": {
                "fullTime": 11,
                "partTime": 8
            }
        }
    },
    {
        "_id": "70032165-fded-47b4-84a3-8d9c18a4d1e7",
        "name": "Northwind Traders | Picture Frame Bazaar - Lake Joesph",
        "staff": {
            "totalStaff": {
                "fullTime": 14,
                "partTime": 0
            }
        }
    },
    {
        "_id": "dda2a7d2-6984-40cc-bbea-4cbfbc06d8a3",
        "name": "Contoso, Ltd. | Home Improvement Closet - Jaskolskiview",
        "staff": {
            "totalStaff": {
                "fullTime": 16,
                "partTime": 8
            }
        }
    }
]
```

### Example 2: Use AND operator as boolean-expression to find stores with high sales and sufficient staff

This query finds stores that have both total sales greater than 100,000 and more than 30 total staff members.

```javascript
db.stores.aggregate([
  {
    $project: {
      name: 1,
      totalSales: "$sales.totalSales",
      totalStaff: {
        $add: ["$staff.employeeCount.fullTime", "$staff.employeeCount.partTime"]
      },
      meetsHighPerformanceCriteria: {
        $and: [
          { $gt: ["$sales.totalSales", 100000] },
          { $gt: [{ $add: ["$staff.employeeCount.fullTime", "$staff.employeeCount.partTime"] }, 30] }
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
    "totalStaff": 31,
    "meetsHighPerformanceCriteria": false
  },
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "totalStaff": 27,
    "meetsHighPerformanceCriteria": false
  }
]
```
