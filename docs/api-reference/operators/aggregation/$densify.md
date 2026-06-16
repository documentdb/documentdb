---
title: $densify
description: The $densify operator adds missing data points in a sequence of values within an array or collection.
type: operators
category: aggregation
---

# $densify

The `$densify` stage in an aggregation pipeline is used to fill in missing data points within a sequence of values. It helps in creating a more complete dataset by generating missing values based on a specified field, range, and step. This is useful in scenarios like time-series data analysis, where gaps in data points need to be filled to ensure accurate analysis.

## Syntax

```javascript
{
  $densify: {
    field: <field>,
    range: {
      step: <number>,
      unit: <string>, // Optional, e.g., "hour", "day", "month", etc.
      bounds: [<lowerBound>, <upperBound>] // Optional
    },
    partitionByFields: [<field1>, <field2>, ...] // Optional
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field on which densification is performed. |
| **`range.step`** | The step size for generating missing values. |
| **`range.unit`** | (Optional) The unit of the step size, such as time units (e.g., "hour", "day"). |
| **`range.bounds`** | (Optional) Specifies the range (lower and upper bounds) for densification. |
| **`partitionByFields`** | (Optional) Fields used to group data for densification. |

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

### Example 1: Densify a time-series dataset

This query fills in missing days in the date field.

```javascript
db.aggregate([
    {
      $documents: [
        { date: new ISODate("2024-01-01"), value: 10 },
        { date: new ISODate("2024-01-03"), value: 15 }
      ]
    },
    {
      $densify: {
        field: "date",
        range: {
          step: 1,
          unit: "day",
          bounds: "full"
        }
      }
    }
  ]);
```

This query returns the following results:

```json
[
    {
        "date": "ISODate('2024-01-01T00:00:00.000Z')",
        "value": 10
    },
    {
        "date": "ISODate('2024-01-02T00:00:00.000Z')"
    },
    {
        "date": "ISODate('2024-01-03T00:00:00.000Z')",
        "value": 15
    }
]

```

### Example 2: Densify numeric data

This query fills in missing numeric values in the `sales.fullSales` field:

```javascript
db.aggregate([
    {
      $documents: [
        { level: 1, score: 10 },
        { level: 3, score: 30 }
      ]
    },
    {
      $densify: {
        field: "level",
        range: {
          step: 1,
          bounds: [1, 5] 
        }
      }
    }
  ]);
```

This query returns the following results:

```json
[
    {
        "level": 1,
        "score": 10
    },
    {
        "level": 2
    },
    {
        "level": 3,
        "score": 30
    },
    {
        "level": 4
    }
]
```

## Limitations

The following table summarizes the key restrictions and behaviors associated with the $densify stage in aggregation pipelines:

| Category| Condition / Behavior |
| --- | --- |
| Field Restrictions | - Errors if any document has a **date** value and `unit` is **not specified**. <br> - Errors if any document has a **numeric** value and `unit` is **specified**. <br> - Field name **starts with `$`**. Use `$project` to rename it.|
| partitionByFields | - Any field evaluates to a **non-string** value. <br> - Field name **starts with `$`**. |
| range.bounds | - **Lower bound** defines the start value, regardless of existing documents. <br> - **Lower bound is inclusive**. <br> - **Upper bound is exclusive**. <br> - `$densify` does **not filter out** documents outside the bounds. |
