---
title: $geoNear
description: The $geoNear operator finds and sorts documents by their proximity to a geospatial point, returning distance information for each document.
type: operators
category: aggregation
---

# $geoNear

The `$geoNear` aggregation stage calculates distances between a specified point and the location field in each document, sorts the documents by distance, and can optionally limit results by distance.

## Syntax

```javascript
{
  $geoNear: {
    near: {
      type: "Point",
      coordinates: [<longitude>, <latitude>]
    },
    distanceField: <field to store distance>,
    maxDistance: <optional maximum distance in meters>,
    minDistance: <optional minimum distance in meters>,
    query: <optional query conditions>,
    includeLocs: <optional boolean to include locations>,
    distanceMultiplier: <optional distance multiplier>,
    spherical: <boolean, must be true>,
    key: <optional field path>
  }
}
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `near` | Object | The point from which to calculate distances |
| `distanceField` | String | The field that contains computed distance |
| `maxDistance` | Number | Optional. Maximum distance in meters from point |
| `minDistance` | Number | Optional. Minimum distance in meters from point |
| `query` | Document | Optional query conditions |
| `includeLocs` | Boolean | Optional. Include locations in results |
| `distanceMultiplier` | Number | Optional. Multiply distances by this value |
| `spherical` | Boolean | Must be true for 2dsphere indexes |
| `key` | String | Optional. Field path to use for calculating distances |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
  "name": "First Up Consultants | Bed and Bath Center - South Amir",
  "location": {
    "lat": 60.7954,
    "lon": -142.0012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 18,
      "partTime": 17
    }
  },
  "sales": {
    "totalSales": 37701,
    "salesByCategory": [
      {
        "categoryName": "Mattress Toppers",
        "totalSales": 37701
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Price Drop Palooza",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 21
        },
        "endDate": {
          "Year": 2024,
          "Month": 9,
          "Day": 30
        }
      },
      "discounts": [
        {
          "categoryName": "Bath Accessories",
          "discountPercentage": 18
        },
        {
          "categoryName": "Pillow Top Mattresses",
          "discountPercentage": 17
        }
      ]
    }
  ]
}
```

### Example 1: Basic distance calculation

This query retrieves all stores near the "VanArsdel Picture Frame Store" location, sorted by distance:

```javascript
db.stores.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [-141.9922, 16.8331]  // VanArsdel Picture Frame Store location
      },
      distanceField: "distance",
      spherical: true
    }
  },
  {
    $project: {
      name: 1,
      distance: 1
    }
  }
])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "643b2756-c22d-4063-9777-0945b9926346",
        "name": "Contoso, Ltd. | Outdoor Furniture Corner - Pagacfort",
        "distance": 5458613.2813355485
    },
    {
        "_id": "daa71e60-75d4-4e03-8b45-9df59af0811f",
        "name": "First Up Consultants | Handbag Corner - South Salvatore",
        "distance": 5469362.958855379
    },
    {
        "_id": "02a78a15-b1fc-4bbd-ae1d-641b7428dc78",
        "name": "VanArsdel, Ltd. | Kitchen Appliance Corner - Llewellynberg",
        "distance": 5472684.4628977
    }
]
```

### Example 2: With distance limits and optional query

This query retrieves all stores within 30 KM of "Proseware Home Entertainment Hub" that have more than 10 full-time staff:

```javascript
db.stores.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [69.7296, 70.1272]  // "Proseware Home Entertainment Hub" location
      },
      distanceField: "distance",
      maxDistance: 30000,  // 30 kilometers in meters
      query: { "staff.totalStaff.fullTime": { $gt: 10 } },
      spherical: true
    }
  },
  {
    $project: {
      name: 1,
      distance: 1,
      "staff.totalStaff.fullTime": 1
    }
  }
])
```

The first result returned by this query is:

```javascript
[
    {
        "_id": "bbec6d3e-1666-45b4-8803-8b7ef8544845",
        "name": "First Up Consultants | Baby Products Bargains - South Keenan",
        "staff": {
            "totalStaff": {
                "fullTime": 19
            }
        },
        "distance": 29934.71888123174
    }
]
```

### Example 3: Including location data and distance multiplier

This query retrieves stores with distance in kilometers and included location data:

```javascript
db.stores.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [-38.4071, -47.2548]  // "Fabrikam Car Accessory Outlet" location
      },
      distanceField: "distanceInKm",
      includeLocs: "storeLocation",
      distanceMultiplier: 0.001,  // Convert meters to kilometers
      spherical: true
    }
  },
  {
    $project: {
      name: 1,
      distanceInKm: 1,
      storeLocation: 1
    }
  }
])
```

The first three results returned by this query are:

```javascript
[
    {
        "_id": "b677846e-bb73-46ec-9cba-7d94afee382c",
        "name": "Northwind Traders | Health Food Shoppe - Brooklynmouth",
        "storeLocation": {
            "lat": -38.3032,
            "lon": -132.7866
        },
        "distanceInKm": 9.095634270192285
    },
    {
        "_id": "27c64b44-2382-4477-b3ce-c08e74882156",
        "name": "Relecloud | VR Headset Gallery - West Jonasbury",
        "storeLocation": {
            "lat": -37.9628,
            "lon": -132.6637
        },
        "distanceInKm": 34.7104536140246
    },
    {
        "_id": "505e83eb-09bc-46a4-ba85-16135611b9de",
        "name": "Fabrikam, Inc. | Pharmacy Hub - Elijahville",
        "storeLocation": {
            "lat": -38.0349,
            "lon": -47.9571
        },
        "distanceInKm": 82.92766541748313
    }
]
```

## Limitations

* Can't use with sharded collections
* Only one $geoNear stage per pipeline
* Must be the first stage in the pipeline
