---
title: $dateTrunc
description: The $dateTrunc operator truncates a date to a specified unit.
type: operators
category: date-expression
---

# $dateTrunc

The `$dateTrunc` expression operator truncates a date to the nearest specified unit (for example, hour, day, month). It's useful when working with time-series data or when grouping data by specific time intervals. This operator can be used to simplify and standardize date calculations.

## Syntax

```javascript
  $dateTrunc: {
    date: <dateExpression>,
    unit: "<unit>",
    binSize: <number>,       // optional
    timezone: "<timezone>",  // optional
    startOfWeek: "<day>"     // optional (used when unit is "week")
  }
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`date`** | The date to truncate. |
| **`unit`** | The unit to truncate the date to. Supported values include `year`, `month`, `week`, `day`, `hour`, `minute`, `second`, and `millisecond`. |
| **`binSize`** | (Optional) The size of each bin for truncation. For example, if `binSize` is 2 and `unit` is `hour`, the date is truncated to every 2 hours. |
| **`timezone`** | (Optional) The timezone to use for truncation. Defaults to UTC if not specified. |

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

### Example 1: Truncate to the day

This query uses `$dateTrunc` to truncate the `lastUpdated` timestamp to the start of the day (00:00:00) in UTC. The operator is useful for grouping or comparing data by calendar day regardless of time.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      truncatedToDay: {
        $dateTrunc: {
          date: "$lastUpdated",
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
    "truncatedToDay": "2024-11-29T00:00:00.000Z"
  }
]
```

### Example 2: Truncate to the start of the week

This query uses `$dateTrunc` to round the `lastUpdated` timestamp down to the start of its week. It specifies Monday as the start of the week to ensure consistent calendar alignment.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      truncatedToWeek: {
        $dateTrunc: {
          date: "$lastUpdated",
          unit: "week",
          startOfWeek: "Monday"
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
    "truncatedToWeek": "2024-11-25T00:00:00.000Z"
  }
]
```
