---
title: $cond
description: The $cond operator is used to evaluate a condition and return one of two expressions based on the result.
type: operators
category: conditional-expression
---

# $cond

The `$cond` operator is used to evaluate a condition and return one of two expressions based on the result. It's similar to the ternary operator in many programming languages. The `$cond` operator can be used within aggregation pipelines to add conditional logic to your queries.

## Syntax

```javascript
{
   $cond: {
      if: <boolean-expression>,
      then: <true-case>,
      else: <false-case>
   }
}
```

### Parameters

| Parameter | Description |
| --- | --- |
| **if**| A boolean expression that is evaluated.|
| **then**| The expression to return if the `if` condition evaluates to true.|
| **else**| The expression to return if the `if` condition evaluates to false.|

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

### Example 1: Determine high sales categories

This query determines if the sales for each category are considered "high" or "low" based on a threshold value of $250,000.

```javascript
db.stores.aggregate([{
        $project: {
            _id: 0,
            storeId: "$storeId",
            category: "$sales.salesByCategory.categoryName",
            sales: "$sales.salesByCategory.totalSales",
            salesCategory: {
                $cond: {
                    if: {
                        $gte: ["$sales.salesByCategory.totalSales", 250000]
                    },
                    then: "High",
                    else: "Low"
                }
            }
        }
    },
    // Limit the result to the first 3 documents
    {
        $limit: 3
    }
])
```

The first three results returned by this query are:

```json
[
    {
        "sales": [
            35921,
            1000
        ],
        "category": [
            "DJ Headphones",
            "DJ Cables"
        ],
        "salesCategory": "High"
    },
    {
        "sales": [
            4760
        ],
        "category": [
            "Guitars"
        ],
        "salesCategory": "High"
    },
    {
        "sales": [
            14697,
            44111,
            37854,
            46211,
            7269,
            25451,
            21083
        ],
        "category": [
            "Washcloths",
            "Innerspring Mattresses",
            "Microfiber Towels",
            "Shower Curtains",
            "Bathrobes",
            "Tablecloths",
            "Bath Accessories"
        ],
        "salesCategory": "High"
    }
]
```

### Example 2: Determine full-time or part-time dominance

This query determines whether a store employs more full-time or part-time staff.

```javascript
db.stores.aggregate([{
        $project: {
            name: 1,
            staffType: {
                $cond: {
                    if: {
                        $gte: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
                    },
                    then: "More Full-Time",
                    else: "More Part-Time"
                }
            }
        }
    },
    // Limit the result to the first 3 documents
    {
        $limit: 3
    }
])
```

The first three results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
    "staffType": "More Full-Time"
  },
  {
    "_id": "649626c9-eda1-46c0-a27f-dcee19d97f41",
    "name": "VanArsdel, Ltd. | Musical Instrument Outlet - East Cassie",
    "staffType": "More Full-Time"
  },
  {
    "_id": "8345de34-73ec-4a99-9cb6-a81f7b145c34",
    "name": "Northwind Traders | Bed and Bath Place - West Oraland",
    "staffType": "More Part-Time"
  }
]
```
