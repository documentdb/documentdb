---
title: $isoWeekYear
description: The $isoWeekYear operator returns the year number in ISO 8601 format, which can differ from the calendar year for dates at the beginning or end of the year.
type: operators
category: date-expression
---

# $isoWeekYear

The `$isoWeekYear` operator returns the year number in ISO 8601 format. The ISO week-numbering year can differ from the calendar year for dates at the beginning or end of the year. The ISO week year is the year that contains the Thursday of the week in question.

## Syntax

```javascript
{
  $isoWeekYear: <dateExpression>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateExpression`** | An expression that resolves to a Date, Timestamp, or ObjectId. If the expression resolves to null or is missing, `$isoWeekYear` returns null. |

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

### Example 1: Compare calendar year vs ISO week year

This query demonstrates the difference between calendar year and ISO week year, especially for dates near year boundaries.

```javascript
db.stores.aggregate([
  { $match: {_id: "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
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
      },
      endDate: {
        $dateFromParts: {
          year: "$promotionEvents.promotionalDates.endDate.Year",
          month: "$promotionEvents.promotionalDates.endDate.Month",
          day: "$promotionEvents.promotionalDates.endDate.Day"
        }
      }
    }
  },
  {
    $project: {
      eventName: 1,
      startDate: 1,
      endDate: 1,
      startCalendarYear: { $year: "$startDate" },
      startISOWeekYear: { $isoWeekYear: "$startDate" },
      endCalendarYear: { $year: "$endDate" },
      endISOWeekYear: { $isoWeekYear: "$endDate" },
      yearDifference: {
        $ne: [{ $year: "$startDate" }, { $isoWeekYear: "$startDate" }]
      }
    }
  },
  { $match: {"eventName": "Discount Delight Days" } }
])
```

This query returns the following result.

```json
[
  {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "eventName": "Discount Delight Days",
    "startDate": "2023-12-26T00:00:00.000Z",
    "endDate": "2024-01-05T00:00:00.000Z",
    "startCalendarYear": 2023,
    "startISOWeekYear": Long("2023"),
    "endCalendarYear": 2024,
    "endISOWeekYear": Long("2024"),
    "yearDifference": true
  }
]
```
