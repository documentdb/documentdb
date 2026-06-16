---
title: $dateSubtract
description: The $dateSubtract operator subtracts a specified amount of time from a date.
type: operators
category: date-expression
---

# $dateSubtract

The `$dateSubtract` operator subtracts a specified time unit from a date. It's useful for calculating past dates or intervals in aggregation pipelines.

## Syntax

```javascript
{
  $dateSubtract: {
    startDate: <dateExpression>,
    unit: "<unit>",
    amount: <number>,
    timezone: "<timezone>" // optional
  }
}
```

## Parameters

| Parameter       | Description                                      |
| --------------- | ------------------------------------------------ |
| **`startDate`** | The date expression to subtract from.            |
| **`unit`**      | The time unit to subtract (for example, "day", "hour"). |
| **`amount`**    | The amount of the time unit to subtract.         |
| **`timezone`**  | *(Optional)* Timezone for date calculation.      |

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

### Example 1: Subtract seven days

This query calculates the date one week before the `lastUpdated` field. This query uses `$dateSubtract` to calculate the date exactly seven days before the `storeOpeningDate` timestamp.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      dateOneWeekAgo: {
        $dateSubtract: {
          startDate: "$storeOpeningDate",
          unit: "day",
          amount: 7
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
    "dateOneWeekAgo": "2024-08-29T11:50:06.549Z"
  }
]
```
