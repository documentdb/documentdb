---
title: $let
description: The $let operator allows defining variables for use in a specified expression, enabling complex calculations and reducing code repetition.
type: operators
category: variable-expression
---

# $let

The `$let` operator is used to define variables for use in a specified expression. It allows you to create temporary variables that can be referenced within the expression, making complex calculations more readable and preventing redundant computations.

## Syntax

```javascript
{
  $let: {
    vars: { 
      <var1>: <expression1>,
      <var2>: <expression2>,
      ...
    },
    in: <expression>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`vars`** | An object that defines the variables and their values. Each variable is assigned the result of an expression. |
| **`in`** | The expression that uses the variables defined in the `vars` object. Variables are referenced using `$$<variable_name>`. |

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

### Example 1: Basic variable usage

Calculate staff efficiency metrics using defined variables.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      staffMetrics: {
        $let: {
          vars: {
            fullTime: "$staff.totalStaff.fullTime",
            partTime: "$staff.totalStaff.partTime",
            totalSales: "$sales.totalSales"
          },
          in: {
            totalStaff: { $add: ["$$fullTime", "$$partTime"] },
            salesPerEmployee: { $divide: ["$$totalSales", { $add: ["$$fullTime", "$$partTime"] }] },
            fullTimeRatio: { $divide: ["$$fullTime", { $add: ["$$fullTime", "$$partTime"] }] }
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
    "_id": '40d6f4d7-50cd-4929-9a07-0a7a133c2e74',
    "name": 'Proseware, Inc. | Home Entertainment Hub - East Linwoodbury',
    "staffMetrics": {
      "totalStaff": 39,
      "salesPerEmployee": 3893.948717948718,
      "fullTimeRatio": 0.5128205128205128
    }
  }
]
```

### Example 2: Nested $let expressions

Calculate location-based insights with nested variable definitions.

```javascript
db.stores.aggregate([
  { $match: {"_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74"} },
  {
    $project: {
      name: 1,
      locationInsights: {
        $let: {
          vars: {
            lat: "$location.lat",
            lon: "$location.lon"
          },
          in: {
            coordinates: { lat: "$$lat", lon: "$$lon" },
            hemisphere: {
              $let: {
                vars: {
                  northSouth: { $cond: [{ $gte: ["$$lat", 0] }, "North", "South"] },
                  eastWest: { $cond: [{ $gte: ["$$lon", 0] }, "East", "West"] }
                },
                in: {
                  latitudeHemisphere: "$$northSouth",
                  longitudeHemisphere: "$$eastWest",
                  quadrant: { $concat: ["$$northSouth", " ", "$$eastWest"] }
                }
              }
            },
            distanceFromEquator: { $abs: "$$lat" },
            distanceFromPrimeMeridian: { $abs: "$$lon" }
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
    "_id": '40d6f4d7-50cd-4929-9a07-0a7a133c2e74',
    "name": 'Proseware, Inc. | Home Entertainment Hub - East Linwoodbury',
    "locationInsights": {
      "coordinates": { "lat": 70.1272, "lon": 69.7296 },
      "hemisphere": {
        "latitudeHemisphere": 'North',
        "longitudeHemisphere": 'East',
        "quadrant": 'North East'
      },
      "distanceFromEquator": 70.1272,
      "distanceFromPrimeMeridian": 69.7296
    }
  }
]
```
