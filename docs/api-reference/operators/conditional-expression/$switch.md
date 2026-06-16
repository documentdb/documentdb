---
title: $switch
description: The $switch operator is used to evaluate a series of conditions and return a value based on the first condition that evaluates to true.
type: operators
category: conditional-expression
---

# $switch

The `$switch` operator is used to evaluate a series of conditions and return a value based on the first condition that evaluates to true. This is useful when you need to implement complex conditional logic within aggregation pipelines.

## Syntax

```javascript
{
  $switch: {
    branches: [
      { case: <expression>, then: <expression> },
      { case: <expression>, then: <expression> }
    ],
    default: <expression>
  }
}
```

### Parameters

| Parameter | Description |
| --- | --- |
| **branches**| An array of documents, each containing|
| **case**| An expression that evaluates to either `true` or `false`|
| **then**| The expression to return if the associated `case` expression evaluates to `true`|
| **default**| The expression to return if none of the `case` expressions evaluate to `true`. This field is optional.|

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

### Example 1: To determine staff type based on full-time and part-time counts

This query determines the type of staff based on their count.

```javascript
db.stores.aggregate([{
        $project: {
            name: 1,
            staffType: {
                $switch: {
                    branches: [{
                            case: {
                                $eq: ["$staff.totalStaff.partTime", 0]
                            },
                            then: "Only Full time"
                        },
                        {
                            case: {
                                $eq: ["$staff.totalStaff.fullTime", 0]
                            },
                            then: "Only Part time"
                        }
                    ],
                    default: "Both"
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
    "staffType": "Only Full time"
  },
  {
    "_id": "649626c9-eda1-46c0-a27f-dcee19d97f41",
    "name": "VanArsdel, Ltd. | Musical Instrument Outlet - East Cassie",
    "staffType": "Both"
  },
  {
    "_id": "8345de34-73ec-4a99-9cb6-a81f7b145c34",
    "name": "Northwind Traders | Bed and Bath Place - West Oraland",
    "staffType": "Both"
  }
]
```
