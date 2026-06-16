---
title: $nearSphere
description: The $nearSphere operator returns documents whose location fields are near a specified point on a sphere, sorted by distance on a spherical surface.
type: operators
category: geospatial
---

# $nearSphere

The `$nearSphere` operator returns documents with location fields near a specified point on a sphere, calculating distances using spherical geometry. The operator is more accurate for Earth-based calculations than `$near`.

## Syntax

```javascript
{
  <location field>: {
    $nearSphere: {
      $geometry: {
        type: "Point",
        coordinates: [<longitude>, <latitude>]
      },
      $maxDistance: <distance in meters>,
      $minDistance: <distance in meters>
    }
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `location field` | The field containing the GeoJSON Point |
| `$geometry` | GeoJSON Point object specifying the center point |
| `$maxDistance` | Optional. Maximum distance in meters on a spherical surface |
| `$minDistance` | Optional. Minimum distance in meters on a spherical surface |

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

For better performance, start with creating the required `2dsphere` index.

```javascript
db.stores.createIndex({ "location": "2dsphere" })
```

### Example 1: Basic spherical search

The query retrieves stores that are closest to a specified Point (-141.9922, 16.8331) on a spherical (Earth-like) surface.

```javascript
db.stores.find({
  'location': {
    $nearSphere: {
      $geometry: {
        type: "Point",
        coordinates: [-141.9922, 16.8331]
      }
    }
  }
}, {
  name: 1,
  location: 1
}).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "_id": "643b2756-c22d-4063-9777-0945b9926346",
    "name": "Contoso, Ltd. | Outdoor Furniture Corner - Pagacfort",
    "location": {
      "type": "Point",
      "coordinates": [152.1353, -89.8688]
    }
  },
  {
    "_id": "daa71e60-75d4-4e03-8b45-9df59af0811f",
    "name": "First Up Consultants | Handbag Corner - South Salvatore",
    "location": {
      "type": "Point",
      "coordinates": [150.2305, -89.8431]
    }
  }
]
```

### Example 2: Complex distance analysis

This query retrieves stores between 20 meter and 200 meter from Point (65.3765, -44.8674). The query searches in a "donut-shaped" area - finding stores that are at least 20 meters away but no more than 200 meters from the specified point.

```javascript
db.stores.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [65.3765, -44.8674]
      },
      distanceField: "sphericalDistance",
      minDistance: 20,
      maxDistance: 200,
      spherical: true
    }
  },
  {
    $project: {
      name: 1,
      location: 1,
      distanceKm: { $divide: ["$sphericalDistance", 1000] },
      _id: 0
    }
  },
  {
    $limit: 2
  }
])
```

Key difference between the operator `$nearSphere` and `$near`.

* Former uses spherical geometry for distance calculations.
* Former is more accurate for Earth-based distance calculations.
* Former is better for applications requiring precise global distance calculations
