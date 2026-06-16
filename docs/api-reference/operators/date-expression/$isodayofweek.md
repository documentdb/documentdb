---
title: $isoDayOfWeek
description: The $isoDayOfWeek operator returns the weekday number in ISO 8601 format, ranging from 1 (Monday) to 7 (Sunday).
type: operators
category: date-expression
---

# $isoDayOfWeek

The `$isoDayOfWeek` operator returns the weekday number in ISO 8601 format, ranging from 1 (Monday) to 7 (Sunday). The operator accepts a date expression that resolves to a Date, Timestamp, or ObjectId.

## Syntax

```javascript
{
  $isoDayOfWeek: <dateExpression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | An expression that resolves to a Date, Timestamp, or ObjectId. If the expression resolves to null or is missing, `$isoDayOfWeek` returns null. |

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

### Example 1: Analyze promotion events by day of week

This query reviews promotion events to see which days of the week they started on.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  { $unwind: "$promotionEvents" },
  {
    $project: {
      eventName: "$promotionEvents.eventName",
      startDate: {
        $dateFromParts: {
          year: "$promotionEvents.promotionalDates.startDate.Year",
          month: "$promotionEvents.promotionalDates.startDate.Month",
          day: "$promotionEvents.promotionalDates.startDate.Day"
        }
      }
    }
  },
  {
    $group: {
      _id: { $isoDayOfWeek: "$startDate" },
      eventCount: { $sum: 1 },
      events: { $push: "$eventName" }
    }
  },
  {
    $project: {
      _id: 1,
      dayName: {
        $switch: {
          branches: [
            { case: { $eq: ["$_id", 1] }, then: "Monday" },
            { case: { $eq: ["$_id", 2] }, then: "Tuesday" },
            { case: { $eq: ["$_id", 3] }, then: "Wednesday" },
            { case: { $eq: ["$_id", 4] }, then: "Thursday" },
            { case: { $eq: ["$_id", 5] }, then: "Friday" },
            { case: { $eq: ["$_id", 6] }, then: "Saturday" },
            { case: { $eq: ["$_id", 7] }, then: "Sunday" }
          ]
        }
      },
      eventCount: 1,
      events: 1
    }
  },
  { $sort: { "_id": 1 } }
])
```

This query returns the following results:

```json
[
  {
    "_id": 1,
    "eventCount": 1,
    "events": ["Super Sale Spectacular"],
    "dayName": "Monday"
  },
  {
    "_id": 2,
    "eventCount": 1,
    "events": ["Discount Delight Days"],
    "dayName": "Tuesday"
  },
  {
    "_id": 3,
    "eventCount": 1,
    "events": ["Fantastic Deal Days"],
    "dayName": "Wednesday"
  },
  {
    "_id": 4,
    "eventCount": 1,
    "events": ["Massive Markdown Mania"],
    "dayName": "Thursday"
  },
  {
    "_id": 6,
    "eventCount": 1,
    "events": ["Major Bargain Bash"],
    "dayName": "Saturday"
  },
  {
    "_id": 7,
    "eventCount": 1,
    "events": ["Grand Deal Days"],
    "dayName": "Sunday"
  }
]
```
