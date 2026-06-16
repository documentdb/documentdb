---
title: $sqrt
description: The $sqrt operator calculates and returns the square root of an input number
type: operators
category: arithmetic-expression
---

# $sqrt

The `$sqrt` operator is used to calculate the square root of a specified number.

## Syntax

```javascript
{
  $sqrt: <expression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression>`**| Any valid expression that resolves to a number. |

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

### Example 1: Calculate the square root of sales

To calculate the square root of the sales volumes of each store under the "First Up Consultants" company, first run a query to filter stores by the company name. Then, use the $sqrt operator on the totalSales field to retrieve the desired results.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $project: {
        name: 1,
        "sales.revenue": 1,
        categoryName: "$promotionEvents.discounts.categoryName",
        sqrtFullSales: {
            $sqrt: "$sales.revenue"
        }
    }
}])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "c52c9f65-5b1a-4ef5-a7a2-d1af0426cbe4",
        "name": "First Up Consultants | Jewelry Pantry - Nicolasberg",
        "sales": {
            "revenue": 4624
        },
        "categoryName": [
            [
                "Watches",
                "Bracelets"
            ],
            [
                "Brooches",
                "Necklaces"
            ],
            [
                "Charms",
                "Brooches"
            ],
            [
                "Brooches",
                "Anklets"
            ],
            [
                "Earrings",
                "Anklets"
            ]
        ],
        "sqrtFullSales": 68
    },
    {
        "_id": "176aa484-c21c-44ce-ab6d-5e097bbdc2b4",
        "name": "First Up Consultants | Medical Supply Shop - Daughertyville",
        "sales": {
            "revenue": 67311
        },
        "categoryName": [
            [
                "First Aid Kits",
                "OTC Medications"
            ],
            [
                "Blood Pressure Monitors",
                "OTC Medications"
            ],
            [
                "Face Masks",
                "Stethoscopes"
            ]
        ],
        "sqrtFullSales": 259.44363549719236
    }
]
```
