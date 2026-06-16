---
title: $year
description: The $year operator returns the year for a date as a four-digit number.
type: operators
category: date-expression
---

# $year

The `$year` operator returns the year for a date as a four-digit number (for example, 2024). If the date is null or missing, `$year` returns null.

## Syntax

The syntax for the `$year` operator is as follows:

```javascript
{
  $year: <dateExpression>
}
```

Or with timezone specification

```javascript
{
  $year: {
    date: <dateExpression>,
    timezone: <timezoneExpression>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | Any expression that resolves to a Date, Timestamp, or ObjectId. |
| **`timezone`** | Optional. The timezone to use for the calculation. Can be an Olson Timezone Identifier (for example, "America/New_York") or a UTC offset (for example, "+0530"). |

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

### Example 1: Extract year from store opening date

This query extracts the year when the store was opened.

```javascript
db.stores.aggregate([
  { $match: { _id: "905d1939-e03a-413e-a9c4-221f74055aac" } },
  {
    $project: {
      name: 1,
      storeOpeningDate: 1,
      openingYear: { $year: { $toDate: "$storeOpeningDate" } }
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
    "openingYear": 2024
  }
]
```

### Example 2: Find stores opened in specific year

This query retrieves all stores that were opened in 2021.

```javascript
db.stores.aggregate([
  {
    $match: {
      $expr: {
        $eq: [{ $year: { $toDate: "$storeOpeningDate" } }, 2021]
      }
    }
  },
  {
    $project: {
      name: 1,
      city: 1,
      openingYear: { $year: { $toDate: "$storeOpeningDate" } },
      storeOpeningDate: 1
    }
  }
])
```

This query returns the following result.

```json
[
  {
    "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
    "city": "South Amir",
    "storeOpeningDate": "2021-10-03T00:00:00.000Z",
    "name": "First Up Consultants | Bed and Bath Center - South Amir",
    "openingYear": 2021
  }
]
```
