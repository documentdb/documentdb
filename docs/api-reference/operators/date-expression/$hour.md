---
title: $hour
description: The $hour operator returns the hour portion of a date as a number between 0 and 23.
type: operators
category: date-expression
---

# $hour

The `$hour` operator returns the hour portion of a date as a number between 0 and 23. The operator accepts a date expression that resolves to a Date, Timestamp, or ObjectId.

## Syntax

```javascript
{
  $hour: <dateExpression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | An expression that resolves to a Date, Timestamp, or ObjectId. If the expression resolves to null or is missing, `$hour` returns null. |

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

### Example 1: Extract hour from current date

This query extracts the `hour` from the current date and time.

```javascript
db.stores.aggregate([
  { $match: { "_id": "e6410bb3-843d-4fa6-8c70-7472925f6d0a" } },
  {
    $project: {
      name: 1,
      storeOpeningDate: 1,
      currentHour: { $hour: new Date() },
      documentHour: { $hour: "$storeOpeningDate" }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "e6410bb3-843d-4fa6-8c70-7472925f6d0a",
    "name": "Relecloud | Toy Collection - North Jaylan",
    "storeOpeningDate": "2024-09-05T11:50:06.549Z",
    "currentHour": 12,
    "documentHour": 11
  }
]
```
