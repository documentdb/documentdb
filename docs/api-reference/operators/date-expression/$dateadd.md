---
title: $dateAdd
description: The $dateAdd operator adds a specified number of time units (day, hour, month etc) to a date.
type: operators
category: date-expression
---

# $dateAdd

The `$dateAdd` operator adds a specified number of time units to a date. It's useful in scenarios where you need to calculate future dates based on a given date and a time interval.

## Syntax

```javascript
$dateAdd: {
   startDate: <expression>,
   unit: <string>,
   amount: <number>,
   timezone: <string>  // Optional
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`startDate`** | The starting date for the addition operation. |
| **`unit`** | The unit of time to add. Valid units include: `year`, `quarter`, `month`, `week`, `day`, `hour`, `minute`, `second`, `millisecond`. |
| **`amount`** | The number of units to add. |
| **`timezone`** | Optional. The timezone to use for the operation. |

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

### Example 1: Adding days to a date

This query projects `eventName` and computes a `newEndDate` by adding 7 days to a date constructed from nested year, month, and day fields. The result is a simplified document showing the event name and its extended end date.

```javascript
db.stores.aggregate([
  { $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" } },
  { $unwind: "$promotionEvents" },
  { $unwind: "$promotionEvents.promotionalDates" },
  {
    $project: {
      eventName: 1,
      newEndDate: {
        $dateAdd: {
          startDate: {
            $dateFromParts: {
              year: "$promotionEvents.promotionalDates.endDate.Year",
              month: "$promotionEvents.promotionalDates.endDate.Month",
              day: "$promotionEvents.promotionalDates.endDate.Day"
            }
          },
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
     "_id": "e6410bb3-843d-4fa6-8c70-7472925f6d0a",
     "newEndDate": "2024-10-06T00:00:00.000Z"
   }
]
```

### Example 2: Adding months to a date

This aggregation query projects the `eventName` and calculates a newStartDate by adding 1 month to a reconstructed start date from nested promotion fields. It helps determine an adjusted event start date based on the original schedule. This query returns each document’s eventName and a newStartDate that is 1 month after the original startDate from nested promotion event data.

```javascript
db.stores.aggregate([
  { $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" } },
  { $unwind: "$promotionEvents" },
  { $unwind: "$promotionEvents.promotionalDates" },
  {
    $project: {
      eventName: "$promotionEvents.eventName",
      newStartDate: {
        $dateAdd: {
          startDate: {
            $dateFromParts: {
              year: "$promotionEvents.promotionalDates.startDate.Year",
              month: "$promotionEvents.promotionalDates.startDate.Month",
              day: "$promotionEvents.promotionalDates.startDate.Day"
            }
          },
          unit: "month",
          amount: 1
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
     "newStartDate": "2024-10-21T00:00:00.000Z"
   }
]
```
