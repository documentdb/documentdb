---
title: $geoWithin
description: The $geoWithin operator selects documents whose location field is completely within a specified geometry.
type: operators
category: geospatial
---

# $geoWithin

The `$geoWithin` operator selects documents whose location field falls completely within a specified geometry. This operator supports various shape operators including `$box`, `$polygon`, `$center`, and `$geometry`.

## Syntax

```javascript
// Using $box
{
  <location field>: {
    $geoWithin: {
      $box: [ [ <bottom left coordinates> ], [ <upper right coordinates> ] ]
    }
  }
}

// Using $center
{
  <location field>: {
    $geoWithin: {
      $center: [ [ <x>, <y> ], <radius> ]
    }
  }
}

// Using $geometry
{
  <location field>: {
    $geoWithin: {
      $geometry: {
        type: <GeoJSON type>,
        coordinates: <coordinates>
      }
    }
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `location field` | The field containing the location coordinates |
| `$box` | Two sets of coordinates defining opposite corners of a box |
| `$center` | Center point coordinates and radius in degrees |
| `$geometry` | GeoJSON object defining the boundary |

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

### Example 1: Find stores defined by $box

For getting better performance, ensure you have a `2dsphere` index.

```javascript
db.stores.createIndex({ location: "2dsphere" })
```

This query finds stores that are located within a specific rectangular area on a map, defined by a box (bounding rectangle).

```javascript
db.stores.find({
  location: {
    $geoWithin: {
      $box: [
        [65.0, 65.0],    // Bottom left corner
        [75.0, 75.0]     // Top right corner
      ]
    }
  }
}, {
  name: 1,
  location: 1
}).limit(2)
```

The first two results returned by this query.

```json
[
 {
    "_id": "40d6f4d7-50cd-4929-9a07-0a7a133c2e74",
    "name": "Proseware, Inc. | Home Entertainment Hub - East Linwoodbury",
    "location": {
      "lat": 70.1272,
      "lon": 69.7296,
      "address": "123 Entertainment Blvd",
      "city": "East Linwoodbury"
    }
  },
  {
    "_id": "fc286536-cb94-45aa-b975-7040fde04cf7",
    "name": "First Up Consultants | Medical Supply Corner - South Elnoraview",
    "location": {
      "lat": 72.2184,
      "lon": 68.9829
    }
  }
]
```

### Example 2: Find stores defined by $center

The query uses a `$geoWithin` operator to find stores within a circular area defined by a center point and a radius.

```javascript
db.stores.find({
  'location': {
    $geoWithin: {
      $center: [
        [-82.5543, -65.105],  // Center point (Wide World Importers location)
        5                     // Radius in degrees
      ]
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
    "_id": "3e962dd0-dffb-49d6-8a96-1d29fa1553d2",
    "name": "Tailwind Traders | Book Center - Lake Marlen",
    "location": { "lat": -85.4034, "lon": -65.9189 }
  },
  {
    "_id": "7e442816-be4c-4919-8f67-d1e9162a511f",
    "name": "Proseware, Inc. | Outdoor Furniture Bargains - North Obieberg",
    "location": { "lat": -84.1013, "lon": -69.5717 }
  }
]
```

### Example 3: Find stores defined by $geometry

This query finds up to two stores whose location falls within the defined rectangular polygon.

```javascript
db.stores.find({
  'location': {
    $geoWithin: {
      $geometry: {
        type: "Polygon",
        coordinates: [[
          [-85.0, -70.0],
          [-85.0, -60.0],
          [-75.0, -60.0],
          [-75.0, -70.0],
          [-85.0, -70.0]
        ]]
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
    "_id": "66fd4cdd-ffc3-44b6-81d9-6d5e9c1f7f9a",
    "name": "Trey Research | Health Food Center - North Michelle",
    "location": { "lat": -77.9951, "lon": -62.7339 }
  },
  {
    "_id": "ea3f775b-f977-4827-ada4-ca7fd8ed0cd4",
    "name": "VanArsdel, Ltd. | Outdoor Equipment Pantry - Port Aleenton",
    "location": { "lat": -76.4516, "lon": -67.2051 }
  }
]
```
