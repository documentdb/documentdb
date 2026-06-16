---
title: $month
description: The $month operator extracts the month portion from a date value.
type: operators
category: date-expression
---

# $month

The `$month` operator extracts the month portion from a date value, returning a number between 1 and 12, where 1 represents January and 12 represents December. This operator is essential for seasonal analysis and monthly reporting.

## Syntax

```javascript
{
  $month: <dateExpression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | An expression that resolves to a Date, a Timestamp, or an ObjectId. If the expression resolves to `null` or is missing, `$month` returns `null`. |

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

### Example 1: Extract month from store opening date

This query extracts the month portion from the store opening date to analyze seasonal opening patterns.

```javascript
db.stores.aggregate([
  { $match: {_id: "905d1939-e03a-413e-a9c4-221f74055aac"} },
  {
    $project: {
      name: 1,
      storeOpeningDate: 1,
      openingMonth: {
        $month: "$storeOpeningDate"
      },
      openingMonthName: {
        $switch: {
          branches: [
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 1] }, then: "January" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 2] }, then: "February" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 3] }, then: "March" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 4] }, then: "April" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 5] }, then: "May" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 6] }, then: "June" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 7] }, then: "July" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 8] }, then: "August" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 9] }, then: "September" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 10] }, then: "October" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 11] }, then: "November" },
            { case: { $eq: [{ $month: "$storeOpeningDate" }, 12] }, then: "December" }
          ]
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
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "storeOpeningDate": "2024-12-30T22:55:25.779Z",
    "openingMonth": 12,
    "openingMonthName": "December"
  }
]
```
