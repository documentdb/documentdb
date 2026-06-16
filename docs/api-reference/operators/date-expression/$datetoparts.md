---
title: $dateToParts
description: The $dateToParts operator decomposes a date into its individual parts such as year, month, day, and more.
type: operators
category: date-expression
---

# $dateToParts

The `$dateToParts` operator is used to extract individual components (Year, Month, Day, Hour, Minute, Second, Millisecond, etc.) from a date object. The operator is useful for scenarios where manipulation or analysis of specific date parts is required, such as sorting, filtering, or aggregating data based on individual date components.

## Syntax

```javascript
$dateToParts: {
  date: <dateExpression>,
  timezone: <string>, // optional
  iso8601: <boolean> // optional
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`date`** | The date expression to extract parts from. |
| **`timezone`** | Optional. Specifies the timezone for the date. Defaults to UTC if not provided. |
| **`iso8601`** | Optional. If true, the operator uses ISO 8601 week date calendar system. Defaults to false. |

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

### Example 1: Extracting date parts from a field

This query uses `$dateToParts` to break down the `lastUpdated` date into components like year, month, day, and time. It helps in analyzing or transforming individual parts of a date for further processing.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      dateParts: {
        $dateToParts: { 
          date: "$lastUpdated" 
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
    "dateParts": {
      "year": 2024,
      "month": 12,
      "day": 4,
      "hour": 11,
      "minute": 50,
      "second": 6,
      "millisecond": 0
    }
  }
]
```

### Example 2: Using timezone

This query extracts the `lastUpdated` timestamp of a specific document and breaks it into date parts like year, month, day, and hour using $dateToParts. Including the "America/New_York" timezone permits the breakdown, reflects the local time instead of UTC.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      datePartsWithTimezone: {
        $dateToParts: { 
          date: "$lastUpdated", 
          timezone: "America/New_York" 
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
    "datePartsWithTimezone": {
      "year": 2024,
      "month": 12,
      "day": 4,
      "hour": 6,
      "minute": 50,
      "second": 6,
      "millisecond": 0
    }
  }
]
```
