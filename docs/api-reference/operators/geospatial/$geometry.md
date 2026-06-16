---
title: $geometry
description: The $geometry operator specifies a GeoJSON geometry for geospatial queries.
type: operators
category: geospatial
---

# $geometry

The `$geometry` operator specifies a GeoJSON geometry object for geospatial queries. It's used within other geospatial operators to define shapes and points for spatial calculations.

## Syntax

```javascript
{
  $geometry: {
    type: <GeoJSON type>,
    coordinates: <coordinates>
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `type` | GeoJSON object type (Point, Polygon, MultiPolygon, etc.) |
| `coordinates` | Coordinates defining the GeoJSON object as an array |

## Examples

Let's understand the usage with sample json from `stores` dataset.

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

### Example 1: Find nearest stores to point geometry

For better performance, start with creating the required `2dsphere` index.

```javascript
db.stores.createIndex({ location: "2dsphere" })
```

The query retrieves up to two stores closest to the point at coordinates [46.2917, -62.6354], ordered by proximity. It uses the $near operator to sort results by distance from a specific point, helping find stores that are geographically nearest to a given location.

```javascript
db.stores.find({
  location: {
    $near: {
      $geometry: {
        type: "Point",
        coordinates: [46.2917, -62.6354]
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
    "_id": "59c355e9-586c-44f8-bbaf-a87989142119",
    "name": "Relecloud | Outdoor Furniture Shop - Chetside",
    "location": { "lat": 46.188, "lon": -62.2789 }
  },
  {
    "_id": "d3a9cc23-e6ae-4806-93ac-1ade2f624742",
    "name": "VanArsdel, Ltd. | Furniture Place - North Dustinside",
    "location": { "lat": 47.3426, "lon": -62.4031 }
  }
]
```

### Example 2: Find nearest stores to polygon geometry

This query finds up to two stores whose locations intersect with a defined rectangular polygon bounded by coordinates from [-80.0, -75.0] to [-55.0, -70.0].

The `$geoIntersects` operator finds stores that overlap with or touch your polygon boundaries - perfect for identifying which locations interact with a specific geographic zone, whether they're fully inside it or just crossing the edge.

```javascript
db.stores.find({
  location: {
    $geoIntersects: {
      $geometry: {
        type: "Polygon",
        coordinates: [[
          [-80.0, -75.0],   // Bottom-left
          [-80.0, -70.0],   // Top-left
          [-55.0, -70.0],   // Top-right
          [-55.0, -75.0],   // Bottom-right
          [-80.0, -75.0]    // Close polygon
        ]]
      }
    }
  }
}, {
  name: 1,
  location: 1,
  city: 1
}).limit(2)
```

The first two results returned by this query.

```json
[
  {
    "_id": "6bba7117-d180-4584-b50c-a2f843e9c9ab",
    "name": "Wide World Importers | Craft Supply Mart - Heaneybury",
    "location": { "lat": -64.4843, "lon": -107.7003 },
    "city": "Heaneybury"
  },
  {
    "_id": "2fd37663-e0ff-41d0-9c5a-3aec86285daa",
    "name": "Relecloud | Cleaning Supply Closet - Patiencehaven",
    "location": { "lat": -70.6077, "lon": -105.9901 },
    "city": "Patiencehaven"
  }
]
```

### Example 3: Find nearest stores to multi-polygon geometry

The example retrieves up to two stores whose locations fall within either of the two defined rectangular regions (MultiPolygon): one near the coordinates [120.0, -13.0] to [125.0, -10.0], and another near [44.0, -64.0] to [48.0, -61.0].

It uses the $geoWithin operator with a MultiPolygon geometry to search for stores enclosed by any of the specified polygons, making it useful for querying across multiple nonadjacent geographic areas simultaneously.

```javascript
db.stores.find({
  location: {
    $geoWithin: {
      $geometry: {
        type: "MultiPolygon",
        coordinates: [
          [[
            [120.0, -13.0],
            [120.0, -10.0],
            [125.0, -10.0],
            [125.0, -13.0],
            [120.0, -13.0]
          ]],
          [[
            [44.0, -64.0],
            [44.0, -61.0],
            [48.0, -61.0],
            [48.0, -64.0],
            [44.0, -64.0]
          ]]
        ]
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
    "_id": "6d70de9c-7b83-426d-81aa-f2173f97b64d",
    "name": "Fabrikam, Inc. | Footwear Haven - Port Erling",
    "location": { "lat": 45.641, "lon": -118.4963 }
  },
  {
    "_id": "96d48224-ce10-4a61-999a-8536d442f81a",
    "name": "Wide World Importers | Eyewear Bazaar - West Oletachester",
    "location": { "lat": 47.3461, "lon": -61.6605 }
  }
]
```
