---
title: $nor
description: The $nor operator performs a logical NOR on an array of expressions and retrieves documents that fail all the conditions.
type: operators
category: logical-query
---

# $nor

The `$nor` operator performs a logical NOR operation on an array of expressions and selects documents that fail all the specified expressions.

## Syntax

```javascript
{
    $nor: [{
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
| `expression` | An array of expressions, all of which must be false for a document to be included |

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

### Example 1: Basic NOR operation

To find stores that neither have more than 15 full-time staff nor more than 20 part-time staff, run a query with the $nor operator on both the conditions. Then, project only the name and staff fields from the stores in the result set.

```javascript
db.stores.find({
    $nor: [{
        "staff.totalStaff.fullTime": {
            $gt: 15
        }
    }, {
        "staff.totalStaff.partTime": {
            $gt: 20
        }
    }]
}, {
    "name": 1,
    "staff": 1
})
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

### Example 2: Complex NOR operation

To find stores without sales over $100,000, without sales of "Digital Watches", or without promotions in September 2024, run a query using the $nor operator on all three conditions. Lastly, project only the name, sales and promotion events from the stores in the result set.

```javascript
db.stores.find({
    $nor: [{
        "sales.totalSales": {
            $gt: 100000
        }
    }, {
        "sales.salesByCategory.categoryName": "Digital Watches"
    }, {
        "promotionEvents": {
            $elemMatch: {
                "promotionalDates.startDate.Month": 9,
                "promotionalDates.startDate.Year": 2024
            }
        }
    }]
}, {
    "name": 1,
    "sales": 1,
    "promotionEvents": 1
})
```

One of the results returned by this query is:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
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
        ]
    }
]
```
