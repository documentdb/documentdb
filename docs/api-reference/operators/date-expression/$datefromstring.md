---
title: $dateFromString
description: The $dateDiff operator converts a date/time string to a date object.
type: operators
category: date-expression
---

# $dateFromString

The `$dateFromString` operator is used to convert a date/time string to a date object. This operation can be useful when dealing with string representations of dates that need to be manipulated or queried as date objects.

## Syntax

```javascript
{
    $dateFromString: {
        dateString: < string > ,
        format: < string > ,
        timezone: < string > ,
        onError: < expression > ,
        onNull: < expression >
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`dateString`** | The date/time string to convert to a date object. |
| **`format`** | (Optional) The date format specification of the `dateString`. |
| **`timezone`** | (Optional) The timezone to use to format the date. |
| **`onError`** | (Optional) The value to return if an error occurs while parsing the `dateString`. |
| **`onNull`** | (Optional) The value to return if the `dateString` is `null` or missing. |

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

### Example 1: Convert promotional event dates to ISO dates

This query constructs full ISO date strings from individual year, month, and day fields using `$concat` and converts them to startDate and endDate using `$dateFromString`. It’s useful when date components are stored separately in documents.

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
      eventName: "$promotionEvents.eventName",
      startDate: {
        $dateFromString: {
          dateString: {
            $concat: [
              { $toString: "$promotionEvents.promotionalDates.startDate.Year" },
              "-",
              {
                $cond: {
                  if: { $lt: ["$promotionEvents.promotionalDates.startDate.Month", 10] },
                  then: { $concat: ["0", { $toString: "$promotionEvents.promotionalDates.startDate.Month" }] },
                  else: { $toString: "$promotionEvents.promotionalDates.startDate.Month" }
                }
              },
              "-",
              {
                $cond: {
                  if: { $lt: ["$promotionEvents.promotionalDates.startDate.Day", 10] },
                  then: { $concat: ["0", { $toString: "$promotionEvents.promotionalDates.startDate.Day" }] },
                  else: { $toString: "$promotionEvents.promotionalDates.startDate.Day" }
                }
              }
            ]
          }
        }
      },
      endDate: {
        $dateFromString: {
          dateString: {
            $concat: [
              { $toString: "$promotionEvents.promotionalDates.endDate.Year" },
              "-",
              {
                $cond: {
                  if: { $lt: ["$promotionEvents.promotionalDates.endDate.Month", 10] },
                  then: { $concat: ["0", { $toString: "$promotionEvents.promotionalDates.endDate.Month" }] },
                  else: { $toString: "$promotionEvents.promotionalDates.endDate.Month" }
                }
              },
              "-",
              {
                $cond: {
                  if: { $lt: ["$promotionEvents.promotionalDates.endDate.Day", 10] },
                  then: { $concat: ["0", { $toString: "$promotionEvents.promotionalDates.endDate.Day" }] },
                  else: { $toString: "$promotionEvents.promotionalDates.endDate.Day" }
                }
              }
            ]
          }
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
    "endDate": "2024-09-29T00:00:00.000Z"
  }
]
```
