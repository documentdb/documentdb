---
title: $divide
description: The $divide operator divides two numbers and returns the quotient.
type: operators
category: arithmetic-expression
---

# $divide

The `$divide` operator divides two numbers and returns the quotient. The $divide operator returns an error if the divisor is zero.

## Syntax

```javascript
{
  $divide: [ <dividend>, <divisor> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<dividend>`** | Any valid expression that resolves to a number to be divided. |
| **`<divisor>`** | Any valid expression that resolves to a nonzero number to divide by. |

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

### Example 1 - Calculate the average sales volume per employee

To calculate the average sales volume per employee, first run a query using the $divide operator to divide the total sales by the staff count. To calculate the percentage of full time staff, use the $divide operator to dive the number of full time staff by the total staff count and project the result as a percentage.

```javascript
db.stores.aggregate([{
        $match: {
            _id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"
        }
    },
    {
        $project: {
            name: 1,
            averageSalesPerStaff: {
                $divide: [
                    "$sales.totalSales",
                    {
                        $add: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
                    }
                ]
            },
            fullTimeStaffPercentage: {
                $multiply: [{
                    $divide: [
                        "$staff.totalStaff.fullTime",
                        {
                            $add: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
                        }
                    ]
                }, 100]
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
    "averageSalesPerStaff": 3893.95,
    "fullTimeStaffPercentage": 48.72
  }
]
```
