---
title: $week
description: The $week operator returns the week number for a date as a value between 0 and 53.
type: operators
category: date-expression
---

# $week

The `$week` operator returns the week number for a date as a value between 0 and 53. Week 0 begins on January 1, and subsequent weeks begin on Sundays. If the date is null or missing, `$week` returns null.

## Syntax

The syntax for the `$week` operator is as follows:

```javascript
{
  $week: <dateExpression>
}
```

Or with timezone specification

```javascript
{
  $week: {
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

### Example 1: Get week number for store opening date

This query extracts the week number from the store opening date.

```javascript
db.stores.aggregate([
  { $match: { _id: "905d1939-e03a-413e-a9c4-221f74055aac" } },
  {
    $project: {
      name: 1,
      storeOpeningDate: 1,
      openingWeek: { $week: { $toDate: "$storeOpeningDate" } }
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
    "storeOpeningDate": ISODate("2024-12-30T22:55:25.779Z"),
    "openingWeek": 52
  }
]
```

### Example 2: Group stores by opening week

This query groups stores by the week they were opened for analysis.

```javascript
db.stores.aggregate([
  {
    $project: {
      name: 1,
      openingWeek: { $week: { $toDate: "$storeOpeningDate" } },
      openingYear: { $year: { $toDate: "$storeOpeningDate" } }
    }
  },
  {
    $group: {
      _id: { week: "$openingWeek", year: "$openingYear" },
      storeCount: { $sum: 1 },
      stores: { $push: "$name" }
    }
  },
  { $sort: { "_id.year": 1, "_id.week": -1 } },
  { $limit : 3 } ])
```

This query returns the following results:

```json
[
  {
    "_id": { "week": 40, "year": 2021 },
    "storeCount": 1,
    "stores": [ "First Up Consultants | Bed and Bath Center - South Amir" ]
  },
  {
    "_id": { "week": 52, "year": 2024 },
    "storeCount": 1,
    "stores": [ "Trey Research | Home Office Depot - Lake Freeda" ]
  },
  {
    "_id": { "week": 50, "year": 2024 },
    "storeCount": 2,
    "stores": [
      "Fourth Coffee | Paper Product Bazaar - Jordanechester",
      "Adatum Corporation | Pet Supply Center - West Cassie"
    ]
  }
]
```
