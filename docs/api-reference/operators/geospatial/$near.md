---
title: $near
description: The $near operator returns documents with location fields that are near a specified point, sorted by distance.
type: operators
category: geospatial
---

# $near

The `$near` operator returns documents whose location field is near a specified point, sorted by distance. It requires a '2dsphere' index and returns documents from nearest to farthest.

## Syntax

```javascript
{
  <location field>: {
    $near: {
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
| `$maxDistance` | Optional. Maximum distance in meters from the center point |
| `$minDistance` | Optional. Minimum distance in meters from the center point |

## Prerequisite

For better performance, start with creating the required `2dsphere` index.

```javascript
db.stores.createIndex({ "location": "2dsphere" })
```

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

### Example 1: Basic proximity search

The query retrieves the two closest stores to a specific geographic point (70.1272, 69.7296) using geospatial search. This query searches for locations closest to the given point and returns stores in ascending order of distance from the point.

```javascript
db.stores.find({
  'location': {
    $near: {
      $geometry: {
        type: "Point",
        coordinates: [69.7296, 70.1272]  // [longitude, latitude]
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
     "_id": "3882eb86-5dd6-4701-9640-f670ccb67859",
     "name": "Fourth Coffee | DJ Equipment Stop - Schuppestad",
     "location": { "lat": 69.4923, "lon": 70.1851 }
   },
   {
     "_id": "bbec6d3e-1666-45b4-8803-8b7ef8544845",
     "name": "First Up Consultants | Baby Products Bargains - South Keenan",
     "location": { "lat": 69.2158, "lon": 70.3328 }
   }
]
```

### Example 2: Using both Min and Max distance

The query retrieves stores within a 20 km to 200 km range from a specified point and calculates their distances in kilometers. This query searches in a "donut-shaped" area - finding stores that are at least 20 meters away but no more than 200 meters from the specified point.

```javascript
db.stores.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [70.3328, 69.2158]
      },
      distanceField: "distance",
      minDistance: 20,
      maxDistance: 200,
      spherical: true
    }
  },
  {
    $project: {
      name: 1,
      location: 1,
      distanceKm: { $divide: ["$distance", 1000] },
      _id: 0
    }
  },
  { $limit: 2 }
])
```
