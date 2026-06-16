---
title: $maxN
description: The $maxN opertor retrieves the top N values based on a specified filtering criteria
type: operators
category: accumulators
---

# $maxN

The `$maxN` operator is used to retrieve the top N values for a field based on a specified filtering criteria.

## Syntax

```javascript
$maxN: {
    input: < field or expression > ,
    n: < number of values to retrieve >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | Specifies the field or expression to evaluate for maximum values. |
| **`n`** | Specifies the number of maximum values to retrieve. Must be a positive integer. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
  "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
  "location": {
    "lat": 60.1441,
    "lon": -141.5012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 2,
      "partTime": 0
    }
  },
  "sales": {
    "salesByCategory": [
      {
        "categoryName": "DJ Headphones",
        "totalSales": 35921
      }
    ],
    "fullSales": 3700
  },
  "promotionEvents": [
    {
      "eventName": "Bargain Blitz Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 3,
          "Day": 11
        },
        "endDate": {
          "Year": 2024,
          "Month": 2,
          "Day": 18
        }
      },
      "discounts": [
        {
          "categoryName": "DJ Turntables",
          "discountPercentage": 18
        },
        {
          "categoryName": "DJ Mixers",
          "discountPercentage": 15
        }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ],
  "company": "Lakeshore Retail",
  "city": "Port Cecile",
  "lastUpdated": {
    "$date": "2024-12-11T10:21:58.274Z"
  }
}
```

### Example 1: Use `$maxN` as `accumulator` to retrieve top two sales categories

This query retrieves the top two sales categories with the high-performing categories or aggregate top categories across stores.

```javascript
db.stores.aggregate([{
        $project: {
            topSalesCategories: {
                $maxN: {
                    input: "$sales.salesByCategory",
                    n: 2
                }
            }
        }
    },
    {
        $limit: 4
    }
])
```

This query returns the following results:

```json
[
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "topSalesCategories": [
      {
        "categoryName": "Stockings",
        "totalSales": 25731
      }
    ]
  },
  {
    "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
    "topSalesCategories": [
      {
        "categoryName": "Markers",
        "totalSales": 3927
      }
    ]
  },
  {
    "_id": "44fdb9b9-df83-4492-8f71-b6ef648aa312",
    "topSalesCategories": [
      {
        "categoryName": "Storage Boxes",
        "totalSales": 2236
      }
    ]
  },
  {
    "_id": "94792a4c-4b03-466b-91f6-821c4a8b2aa4",
    "topSalesCategories": [
      {
        "categoryName": "Travel Backpacks",
        "totalSales": 13189
      },
      {
        "categoryName": "Suitcases",
        "totalSales": 37858
      }
    ]
  }
]
```

### Example 2: Using `$maxN` in `$setWindowFields`

This query retrieves the top N discounts for "Laptops" in 2023 per city. This query filters for "Laptops" discount entries in 2023 and then groups the resulting documents by city.

```javascript
db.stores.aggregate([
  { $unwind: "$promotionEvents" },
  { $unwind: "$promotionEvents.discounts" },
  {
    $match: {
      "promotionEvents.discounts.categoryName": "Laptops",
      "promotionEvents.promotionalDates.startDate.Year": 2023
    }
  },
  {
    $group: {
      _id: "$city",
      allDiscounts: {
        $push: "$promotionEvents.discounts.discountPercentage"
      }
    }
  },
  {
    $project: {
      topDiscounts: {
        $slice: [
          { $sortArray: { input: "$allDiscounts", sortBy: -1 } },
          3 // Top N discounts
        ]
      }
    }
  }
])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "Lake Margareteland",
        "topDiscounts": [
            18
        ]
    },
    {
        "_id": "Horacetown",
        "topDiscounts": [
            13
        ]
    },
    {
        "_id": "D'Amoreside",
        "topDiscounts": [
            9
        ]
    }
]
```

### Example 3: Using `$maxN` operator as array-expression to find top three sales categories

This query retrieves the top three sales values from all sales categories.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      topThreeSales: {
        $maxN: {
          input: "$sales.salesByCategory.totalSales",
          n: 3
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
      "topThreeSales": [43522, 32272, 28946]
    }
]
```
