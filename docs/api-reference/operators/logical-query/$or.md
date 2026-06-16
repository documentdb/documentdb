---
title: $or
description: The $or operator joins query clauses with a logical OR and returns documents that match at least one of the specified conditions.
type: operators
category: logical-query
---

# $or

The `$or` operator performs a logical OR operation on an array of expressions and retrieves documents that satisfy at least one of the specified conditions.

## Syntax

```javascript
{
    $or: [{
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
| `expression` | An array of expressions, where at least one must be true for a document to be included |

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

### Example 1: Use OR operation as logical-query

This query retrieves stores with more than 15 full-time staff or more than 20 part-time staff, run a query using the $or operator on both the conditions. Then, project only the name and staff fields from the stores in the result set.

```javascript
db.stores.find(
  {
    $or: [
      { "staff.employeeCount.fullTime": { $gt: 15 } },
      { "staff.employeeCount.partTime": { $gt: 20 } }
    ]
  },
  {
    "name": 1,
    "staff": 1
  }
).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "dda2a7d2-6984-40cc-bbea-4cbfbc06d8a3",
    "name": "Contoso, Ltd. | Home Improvement Closet - Jaskolskiview",
    "staff": {
      "employeeCount": {
        "fullTime": 16,
        "partTime": 8
      }
    }
  },
  {
    "_id": "44fdb9b9-df83-4492-8f71-b6ef648aa312",
    "name": "Fourth Coffee | Storage Solution Gallery - Port Camilla",
    "staff": {
      "employeeCount": {
        "fullTime": 17,
        "partTime": 15
      }
    }
  }
]
```

### Example 2: Use OR operator as boolean-expression to identify stores with either high sales or large staff

This query retrieves stores that have either total sales greater than 50,000 or more than 25 total staff members.

```javascript
db.stores.aggregate([
  {
    $project: {
      name: 1,
      totalSales: "$sales.totalSales",
      totalStaff: { 
        $add: ["$staff.employeeCount.fullTime", "$staff.employeeCount.partTime"] 
      },
      qualifiesForProgram: {
        $or: [
          { $gt: ["$sales.totalSales", 50000] },
          { $gt: [{ $add: ["$staff.employeeCount.fullTime", "$staff.employeeCount.partTime"] }, 25] }
        ]
      }
    }
  },
  { $limit: 4 }
])
```

The first four results returned by this query are:

```json
[
  {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "totalStaff": 31,
    "qualifiesForProgram": true
  },
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "totalStaff": 27,
    "qualifiesForProgram": true
  },
  {
    "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
    "name": "Lakeshore Retail | Home Decor Hub - Franciscoton",
    "totalStaff": 13,
    "qualifiesForProgram": false
  },
  {
    "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
    "name": "Contoso, Ltd. | Office Supply Deals - South Shana",
    "totalStaff": 2,
    "qualifiesForProgram": false
  }
]
```

## Performance Considerations

- Review the suggestions for finding better performance.
  - Each condition in the `$or` array is evaluated independently
  - Use indexes when possible for better performance
  - Consider the order of conditions for optimal execution
  - Use `$in` instead of `$or` for multiple equality checks on the same field
  - Keep the number of `$or` conditions reasonable
