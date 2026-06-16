---
title: $polygon
description: The $polygon operator defines a polygon for geospatial queries, allowing you to find locations within an irregular shape.
type: operators
category: geospatial
---

# $polygon

The `$polygon` operator defines a polygon for geospatial queries, allowing you to find locations within an irregular shape. The operator is useful for querying locations within complex geographical boundaries.

## Syntax

```javascript
{
  <location field>: {
    $geoWithin: {
      $geometry: {
        type: "Polygon",
        coordinates: [
          [[<longitude1>, <latitude1>], ..., [<longitudeN>, <latitudeN>], [<longitude1>, <latitude1>]]
        ]
      }
    }
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `location field` | The field containing the geospatial data |
| `coordinates` | An array of coordinate pairs forming the polygon. The first and last points must be identical to close the polygon |

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

### Example 1 - Search within a polygon

The query retrieves stores that fall inside a custom polygon region based on the coordinates provided.

```javascript
db.stores.find({
  location: {
    $geoWithin: {
      $geometry: {
        type: "Polygon",
        coordinates: [[
          [-141.9922, 16.8331],  // VanArsdel Picture Frame Store
          [-112.7858, -29.1866], // First Up Consultants Microphone Bazaar
          [-38.4071, -47.2548],  // Fabrikam Car Accessory Outlet
          [-141.9922, 16.8331]   // Close the polygon by repeating first point
        ]]
      }
    }
  }
},
{
  name: 1,
  location: 1
}).limit(2)
```

The first two results returned by this query are:

```json
[
  {
      "_id": "4a417727-a002-4c80-a01f-bc9526b300a5",
      "name": "Northwind Traders | Bed and Bath Deals - East Duane",
      "location": {
        "type": "Point",
        "coordinates": [-46.1444, -60.9697]
      }
    },
    {
      "_id": "1e27040c-7242-4970-8893-e5738e1bc1ca",
      "name": "Northwind Traders | Seasonal Decoration Bazaar - Cassidyberg",
      "location": {
        "type": "Point",
        "coordinates": [-44.3617, -81.2186]
      }
    }
]
```
