---
title: $millisecond
description: The $millisecond operator extracts the milliseconds portion from a date value.
type: operators
category: date-expression
---

# $millisecond

The `$millisecond` operator extracts the milliseconds portion from a date value, returning a number between 0 and 999. This operator is useful for precise timestamp analysis and filtering operations that require millisecond-level granularity.

## Syntax

```javascript
{
  $millisecond: <dateExpression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | An expression that resolves to a Date, a Timestamp, or an ObjectId. If the expression resolves to `null` or is missing, `$millisecond` returns `null`. |

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

### Example 1: Extract milliseconds from store opening date

This query extracts the milliseconds portion from the store opening date.

```javascript
db.stores.aggregate([
  { $match: {_id: "905d1939-e03a-413e-a9c4-221f74055aac"} },
  {
    $project: {
      name: 1,
      storeOpeningDate: 1,
      openingMilliseconds: {
        $millisecond: "$storeOpeningDate"
      }
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "storeOpeningDate": ISODate("2024-09-26T22:55:25.779Z"),
    "openingMilliseconds": 779
  }
]
```
