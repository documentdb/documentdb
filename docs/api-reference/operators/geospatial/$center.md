---
title: $center
description: The $center operator specifies a circle using legacy coordinate pairs for $geoWithin queries.
type: operators
category: geospatial
---

# $center

The `$center` operator specifies a circle using legacy coordinate pairs to be used in `$geoWithin` queries. It defines a circle for a geospatial query on a flat, Euclidean plane.

## Syntax

```javascript
{
  $geoWithin: {
    $center: [ [ <x>, <y> ], <radius> ]
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `<x>` | The x-coordinate of the circle's center point |
| `<y>` | The y-coordinate of the circle's center point |
| `<radius>` | The radius of the circle in the same units as the coordinates |

## Examples

Let's understand the usage with sample json from `stores` dataset.

```json
{
  "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
  "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
  "location": { "lat": -74.0427, "lon": 160.8154 },
  "staff": { "employeeCount": { "fullTime": 9, "partTime": 18 } },
  "sales": {
    "salesByCategory": [ { "categoryName": "Stockings", "totalSales": 25731 } ],
    "revenue": 25731
  },
  "promotionEvents": [
    {
      "eventName": "Mega Savings Extravaganza",
      "promotionalDates": {
        "startDate": { "Year": 2023, "Month": 6, "Day": 29 },
        "endDate": { "Year": 2023, "Month": 7, "Day": 7 }
      },
      "discounts": [
        { "categoryName": "Stockings", "discountPercentage": 16 },
        { "categoryName": "Tree Ornaments", "discountPercentage": 8 }
      ]
    },
    {
      "eventName": "Incredible Discount Days",
      "promotionalDates": {
        "startDate": { "Year": 2023, "Month": 9, "Day": 27 },
        "endDate": { "Year": 2023, "Month": 10, "Day": 4 }
      },
      "discounts": [
        { "categoryName": "Stockings", "discountPercentage": 11 },
        { "categoryName": "Holiday Cards", "discountPercentage": 9 }
      ]
    },
    {
      "eventName": "Massive Deal Mania",
      "promotionalDates": {
        "startDate": { "Year": 2023, "Month": 12, "Day": 26 },
        "endDate": { "Year": 2024, "Month": 1, "Day": 2 }
      },
      "discounts": [
        { "categoryName": "Gift Bags", "discountPercentage": 21 },
        { "categoryName": "Bows", "discountPercentage": 19 }
      ]
    },
    {
      "eventName": "Super Saver Soiree",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 3, "Day": 25 },
        "endDate": { "Year": 2024, "Month": 4, "Day": 1 }
      },
      "discounts": [
        { "categoryName": "Tree Ornaments", "discountPercentage": 15 },
        { "categoryName": "Stockings", "discountPercentage": 14 }
      ]
    },
    {
      "eventName": "Fantastic Savings Fiesta",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 6, "Day": 23 },
        "endDate": { "Year": 2024, "Month": 6, "Day": 30 }
      },
      "discounts": [
        { "categoryName": "Stockings", "discountPercentage": 24 },
        { "categoryName": "Gift Wrap", "discountPercentage": 16 }
      ]
    },
    {
      "eventName": "Price Plunge Party",
      "promotionalDates": {
        "startDate": { "Year": 2024, "Month": 9, "Day": 21 },
        "endDate": { "Year": 2024, "Month": 9, "Day": 28 }
      },
      "discounts": [
        { "categoryName": "Holiday Tableware", "discountPercentage": 13 },
        { "categoryName": "Holiday Cards", "discountPercentage": 11 }
      ]
    }
  ],
  "company": "Lakeshore Retail",
  "city": "Marvinfort",
  "storeOpeningDate": { "$date": "2024-10-01T18:24:02.586Z" },
  "lastUpdated": { "$timestamp": { "t": 1730485442, "i": 1 } },
  "storeFeatures": 38
}
```

### Example 1 - Find stores within a circular area

Let's find all stores within a 50-degree radius of 'First Up Consultants Microphone Bazaar' using our `stores` dataset. This query retrieves stores within a 50-degree radius of the First Up Consultants Microphone Bazaar location.

```javascript
db.stores.find(
  {
    location: {
      $geoWithin: {
        $center: [[-112.7858, -29.1866], 50]
      }
    }
  },
  {
    name: 1,
    city: 1,
    location: 1,
    _id: 0
  }
).limit(2)
```

The query returns stores within 50-degree radius, which could be useful for analyzing market coverage or planning delivery routes.

```json
[
  {
    "name": "Contoso, Ltd. | Baby Products Corner - Port Jerrold",
    "location": { "lat": -72.7709, "lon": -24.3031 },
    "city": "Port Jerrold"
  },
  {
    "name": "VanArsdel, Ltd. | Smart Home Closet - Trystanport",
    "location": { "lat": -64.5509, "lon": -28.7144 },
    "city": "Trystanport"
  }
]
```

> [!IMPORTANT]
> The `$center` operator works on a flat, Euclidean plane.
> 
> For more accurate Earth-like spherical calculations, use `$centerSphere` instead.
> 
> The radius is specified in the same units as the coordinate system being used.
