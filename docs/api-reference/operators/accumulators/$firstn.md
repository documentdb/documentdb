---
title: $firstN
description: The $firstN operator sorts documents on one or more fields specified by the query and returns the first N document matching the filtering criteria
type: operators
category: accumulators
---

# $firstN

The `$firstN` operator returns the first N values in a group according to the group's sorting order. If no sorting order is specified, the order is undefined.

## Syntax

```javascript
{
    $firstN: {
        input: [listOfFields],
        sortBy: {
            <fieldName>: <sortOrder>
        },
        n: <numDocumentsToReturn>
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`listOfFields`** | The list of fields to be returned for the first N documents in the result set|
| **`fieldName`** | The field to use for sorting the result set|
| **`sortOrder`** | 1 or -1. 1 implies sorting in ascending order of the value of the field while -1 implies sorting in descending order of the values of the field|
| **`n`** | The number of documents to return from the top of the sorted result set |

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

### Example 1: Use $firstN operator as accumulator to find first two stores by total sales

To get the top two stores by total sales, run a query to sort all documents in descending order of sales.totalSales and return the first two documents from the sorted result set.

```javascript
db.stores.aggregate([{
        $sort: {
            "sales.totalSales": -1
        }
    },
    {
        $group: {
            _id: null,
            topTwoStores: {
                $firstN: {
                    n: 2,
                    input: {
                        storeId: "$_id",
                        storeName: "$name",
                        totalSales: "$sales.totalSales"
                    }
                }
            }
        }
    }
])
```

This query returns the following result:

```json
[
    {
        "_id": null,
        "topTwoStores": [
            {
                "storeId": "ffe155dd-caa2-4ac1-8ec9-0342241a84a3",
                "storeName": "Lakeshore Retail | Electronics Stop - Vicentastad",
                "totalSales": 399426
            },
            {
                "storeId": "cba62761-10f8-4379-9eea-a9006c667927",
                "storeName": "Fabrikam, Inc. | Electronics Nook - East Verlashire",
                "totalSales": 374845
            }
        ]
    }
]
```

### Example 2: Use $firstN operator as accumulator to find first two categories per store

To retrieve the first two categories by total sales within each store, run a query to sort all documents in descending order of sales.totalSales within the scope of each store and return the first two categories from the sorted result set per store.

```javascript
db.stores.aggregate([
  { $unwind: "$sales.salesByCategory" },
  {
    $match: {
      "sales.salesByCategory.totalSales": { $exists: true }
    }
  },
  {
    $sort: {
      "_id": 1,
      "sales.salesByCategory.totalSales": -1
    }
  },
  {
    $group: {
      _id: "$_id",
      storeName: { $first: "$name" },
      categoryCount: { $sum: 1 },
      firstTwoCategories: {
        $push: {
          categoryName: "$sales.salesByCategory.categoryName",
          totalSales: "$sales.salesByCategory.totalSales"
        }
      }
    }
  },
  {
    $project: {
      storeName: 1,
      categoryCount: 1,
      firstTwoCategories: { $slice: ["$firstTwoCategories", 2] }
    }
  },
  {
    $match: {
      categoryCount: { $gte: 2 }
    }
  },
  { $limit: 2 }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "2e07b49d-1730-491b-b847-44b6a34812c1",
        "storeName": "VanArsdel, Ltd. | Electronics Market – North Bransonborough",
        "categoryCount": 3,
        "firstTwoCategories": [
            {
                "categoryName": "iPads",
                "totalSales": 37113
            },
            {
                "categoryName": "Laptops",
                "totalSales": 9175
            }
        ]
    },
    {
        "_id": "1bec7539-dc75-4f7e-b4e8-afdf8ff2f234",
        "storeName": "Adatum Corporation | Health Food Market – East Karina",
        "categoryCount": 2,
        "firstTwoCategories": [
            {
                "categoryName": "Protein Bars",
                "totalSales": 49900
            },
            {
                "categoryName": "Superfoods",
                "totalSales": 39683
            }
        ]
    }
]
```

### Example 3: Use `firstN` operator as array-expression to find first three sales categories

The example demonstrates the operator usage to find the first three sales categories for analysis.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      totalSales: "$sales.totalSales",
      firstThreeCategories: {
        $firstN: {
          input: "$sales.salesByCategory",
          n: 3
        }
      }
    }
  }
])
```

This query returns the following result:

```json
[
  {
      "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
      "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
      "totalSales": 165000,
      "firstThreeCategories": [
          {
              "categoryName": "Sound Bars",
              "totalSales": 2120
          },
          null,
          {
              "categoryName": "Game Controllers",
              "totalSales": 43522
          }
      ]
  }
]
```
