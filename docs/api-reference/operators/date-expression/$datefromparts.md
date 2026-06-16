---
title: $dateFromParts
description: The $dateFromParts operator constructs a date from individual components.
type: operators
category: date-expression
---

# $dateFromParts

The `$dateFromParts` operator constructs a date from individual components such as year, month, day, hour, minute, second, and millisecond. This operator can be useful when dealing with data that stores date components separately.

## Syntax

```javascript
{
    $dateFromParts: {
        year: < year > ,
        month: < month > ,
        day: < day > ,
        hour: < hour > ,
        minute: < minute > ,
        second: < second > ,
        millisecond: < millisecond > ,
        timezone: < timezone >
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`year`** | The year component of the date. |
| **`month`** | The month component of the date. |
| **`day`** | The day component of the date. |
| **`hour`** | The hour component of the date. |
| **`minute`** | The minute component of the date. |
| **`second`** | The second component of the date. |
| **`millisecond`** | The millisecond component of the date. |
| **`timezone`** | Optional. A timezone specification. |

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

### Example 1: Constructing a start date

This query constructs precise startDate and endDate values from nested fields using `$dateFromParts`, then calculates the event duration in days. It helps standardize and analyze event timelines stored in fragmented date formats.

```javascript
db.stores.aggregate([
  { 
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" } 
  },
  { 
    $unwind: "$promotionEvents" 
  },
  {
    $project: {
      _id: 1,
      startDate: {
        $dateFromParts: {
          year: "$promotionEvents.promotionalDates.startDate.Year",
          month: "$promotionEvents.promotionalDates.startDate.Month",
          day: "$promotionEvents.promotionalDates.startDate.Day"
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
    "startDate": "2024-09-21T00:00:00.000Z"
  }
]
```
