---
title: $subtract
description: The $subtract operator subtracts two numbers and returns the result.
type: operators
category: arithmetic-expression
---

# $subtract

The `$subtract` operator is used to subtract two numbers and return the result.

## Syntax

```javascript
{
  $subtract: [ <expression 1>, <expression 2> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<expression 1>`** | The minuend (the number from which another number is to be subtracted). |
| **`<expression 2>`** | The subtrahend (the number to be subtracted). |

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

### Example 1: Calculating the difference between full time and part time staff

To calculate the absolute difference in part time and full time staff for stores within the "First Up Consultants" company, first run a query to filter stores by the company name. Then, use the $diff operator along with the $abs operator to calculate the absolute difference between the full time and part time staff for each store.

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
        staff: 1,
        staffCountDiff: {
            $abs: {
                $subtract: ["$staff.employeeCount.fullTime", "$staff.employeeCount.partTime"]
            }
        }
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "name": "First Up Consultants | Plumbing Supply Shoppe - New Ubaldofort",
        "staff": {
            "employeeCount": {
                "fullTime": 20,
                "partTime": 18
            }
        },
        "staffCountDiff": 2
    },
    {
        "_id": "bfb213fa-8db8-419f-8e5b-e7096120bad2",
        "name": "First Up Consultants | Beauty Product Shop - Hansenton",
        "staff": {
            "employeeCount": {
                "fullTime": 18,
                "partTime": 10
            }
        },
        "staffCountDiff": 8
    },
    {
        "_id": "14ab145b-0819-4d22-9e02-9ae0725fcda9",
        "name": "First Up Consultants | Flooring Haven - Otisville",
        "staff": {
            "employeeCount": {
                "fullTime": 19,
                "partTime": 10
            }
        },
        "staffCountDiff": 9
    }
]
```
