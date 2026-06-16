---
title: $dateToString
description: The $dateToString operator converts a date object into a formatted string.
type: operators
category: date-expression
---

# $dateToString

The `$dateToString` operator is used to convert a date object to a string in a specified format. It's commonly used in aggregation pipelines to format date fields for reporting, querying, or display purposes. This operator is highly versatile and allows you to define custom date formats.

## Syntax

```javascript
{
  $dateToString: {
    format: "<format_string>",
    date: <date_expression>,
    timezone: "<timezone>",
    onNull: "<replacement_value>"
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`format`** | A string that specifies the format of the output date. |
| **`date`** | The date expression to format. |
| **`timezone`** | (Optional) A string that specifies the timezone. Defaults to UTC if not provided. |
| **`onNull`** | (Optional) A value to return if the `date` field is `null` or missing. |

## Format Specifiers

| Symbol | Meaning                  |
| ------ | ------------------------ |
| `%Y`   | Year (four digits)          |
| `%m`   | Month (two digits)         |
| `%d`   | Day of month (two digits)  |
| `%H`   | Hour (24-hour, two digits) |
| `%M`   | Minute (two digits)        |
| `%S`   | Second (two digits)        |
| `%L`   | Millisecond (three digits)   |

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

### Example 1: Formatting a date field to an ISO-like string

This query uses `$dateToString` operator to format the `lastUpdated` timestamp into a `YYYY-MM-DD` string. It helps present dates in a readable format suitable for logs, reports, or UI.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      formattedDate: {
        $dateToString: {
          format: "%Y-%m-%d",
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
    "formattedDate": "2024-12-04"
  }
]
```

### Example 2: Handling Null Values

This query formats the nonexistent field `lastUpdated_new` timestamp as a `YYYY-MM-DD` string using `$dateToString`. Considering the date is missing or null, it substitutes a fallback string "No date available" via the onNull option.

```javascript
db.stores.aggregate([
  {
    $match: { _id: "e6410bb3-843d-4fa6-8c70-7472925f6d0a" }
  },
  {
    $project: {
      _id: 0,
      formattedDateOrDefault: {
        $dateToString: {
          format: "%Y-%m-%d",
          date: "$lastUpdated_new", // field doesn't exist
          onNull: "No date available"
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
    "formattedDateOrDefault": "No date available"
  }
]
```
