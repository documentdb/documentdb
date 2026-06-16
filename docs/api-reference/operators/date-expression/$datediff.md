---
title: $dateDiff
description: The $dateDiff operator calculates the difference between two dates in various units such as years, months, days, etc.
type: operators
category: date-expression
---

# $dateDiff

The `$dateDiff` operator calculates the difference between two dates in various units such as years, months, days, etc. It's useful for determining the duration between two timestamps in your dataset.

## Syntax

```javascript
$dateDiff: {
   startDate: <expression>,
   endDate: <expression>,
   unit: <string>,
   timezone: <string>, // Optional
   startOfWeek: <string> // Optional
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`startDate`**| The beginning date for the calculation.|
| **`endDate`**| The ending date for the calculation.|
| **`unit`**| The unit of time to measure the difference. Valid values include: `year`, `quarter`, `month`, `week`, `day`, `hour`, `minute`, `second`, `millisecond`.|
| **`timezone`**| Optional. The timezone to use for the calculation.|
| **`startOfWeek`**| Optional. The starting day of the week. Valid values are: `Sunday`, `Monday`, `Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday`.|

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

## Example 1: Calculate duration in days between two dates

This query uses `$dateDiff` to compute the number of units (e.g., days, months) between two date fields. It helps measure durations like event length or time since a given date. This query returns the durationInDays along with other fields for the specified `stores` document.

```javascript
db.stores.aggregate([
  { $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" } },
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
      },
      durationInDays: {
        $dateDiff: {
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
          },
          unit: "day"
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
     "_id": "e6410bb3-843d-4fa6-8c70-7472925f6d0a",
     "eventName": "Massive Markdown Mania",
     "startDate": "2024-09-21T00:00:00.000Z",
     "endDate": "2024-09-29T00:00:00.000Z",
     "durationInDays": 8
   }
]
```
