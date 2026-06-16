---
title: $minN
description: The $minN operator retrieves the bottom N values based on a specified filtering criteria
type: operators
category: accumulators
---

# $minN

The `$minN` operator is used to retrieve the bottom N values for a field based on a specified filtering criteria.

## Syntax

```javascript
$minN: {
    input: < field or expression > ,
    n: < number of values to retrieve >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`input`** | Specifies the field or expression to evaluate for minimum values. |
| **`n`** | Specifies the number of minimum values to retrieve. Must be a positive integer. |

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

### Example 1: Retrieve bottom two sales categories

This query retrieves the bottom two sales categories per store with the lowest sales volume. Run a query using the $minN operator on the nested salesCategory field.

```javascript
db.stores.aggregate([{
        $project: {
            bottomSalesCategories: {
                $minN: {
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
        "bottomSalesCategories": [
            {
                "categoryName": "Stockings",
                "totalSales": 25731
            }
        ]
    },
    {
        "_id": "923d2228-6a28-4856-ac9d-77c39eaf1800",
        "bottomSalesCategories": [
            {
                "categoryName": "Lamps",
                "totalSales": 19880
            },
            {
                "categoryName": "Rugs",
                "totalSales": 20055
            }
        ]
    },
    {
        "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
        "bottomSalesCategories": [
            {
                "categoryName": "Markers",
                "totalSales": 3927
            }
        ]
    },
    {
        "_id": "44fdb9b9-df83-4492-8f71-b6ef648aa312",
        "bottomSalesCategories": [
            {
                "categoryName": "Storage Boxes",
                "totalSales": 2236
            }
        ]
    }
]
```

### Example 2 - Using $minN with $setWindowFields

To get the bottom two lists of sales categories by sales volume across all stores within the "First Up Consultants" company, first run a query to partition the stores by the company. Then, use the $minN operator to determine the two categories with the lowest sales within each partition.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $setWindowFields: {
        partitionBy: "$company",
        sortBy: {
            "sales.totalSales": -1
        },
        output: {
            minTwoBySales: {
                $minN: {
                    input: "$sales.totalSales",
                    n: 2
                }
            }
        }
    }
}, {
    $project: {
        company: 1,
        name: 1,
        minCategoriesBySales: 1
    }
}])
```

The first result returned by this query is:

```json
[
    {
        "_id": "a0386810-b6f8-4b05-9d60-e536fb2b0026",
        "name": "First Up Consultants | Electronics Stop - South Thelma",
        "company": "First Up Consultants",
        "minCategoriesBySales": [
            [
                {
                    "categoryName": "3D Printers",
                    "totalSales": 20882
                },
                {
                    "categoryName": "Phone Mounts",
                    "totalSales": 13624
                },
                {
                    "categoryName": "Prepaid Phones",
                    "totalSales": 7182
                },
                {
                    "categoryName": "MacBooks",
                    "totalSales": 10541
                },
                {
                    "categoryName": "Chargers",
                    "totalSales": 37542
                },
                {
                    "categoryName": "Student Laptops",
                    "totalSales": 43977
                },
                {
                    "categoryName": "Screen Protectors",
                    "totalSales": 14648
                },
                {
                    "categoryName": "Photo Printers",
                    "totalSales": 40064
                },
                {
                    "categoryName": "Printer Ink",
                    "totalSales": 30784
                },
                {
                    "categoryName": "Smartphone Cases",
                    "totalSales": 30468
                },
                {
                    "categoryName": "Printer Drums",
                    "totalSales": 34980
                },
                {
                    "categoryName": "Desktops",
                    "totalSales": 3890
                }
            ],
            [
                {
                    "categoryName": "4K Camcorders",
                    "totalSales": 10466
                },
                {
                    "categoryName": "Tripods",
                    "totalSales": 30942
                },
                {
                    "categoryName": "Camcorder Accessories",
                    "totalSales": 25601
                }
            ]
        ]
    }
]
```

### Example 3 - Using $minN operator as array-expression to get lowest two sales values

This query extracts the two lowest sales values for a specific store document.

```javascript
db.stores.aggregate([
  { $match: {_id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      lowestTwoSales: {
        $minN: {
          input: "$sales.salesByCategory.totalSales",
          n: 2
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
      "lowestTwoSales": [28946, 3000]
    }
]
```
