---
title: $geoIntersects
description: The $geoIntersects operator selects documents whose location field intersects with a specified GeoJSON object.
type: operators
category: geospatial
---

# $geoIntersects

The `$geoIntersects` operator selects documents whose location field intersects with a specified GeoJSON object. This operator is useful when you want to find stores that intersect with a specific geographical area.

## Syntax

```javascript
{
  <location field>: {
    $geoIntersects: {
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
| `location field` | The field containing the GeoJSON object |
| `type` | The GeoJSON object type (for example, "Polygon", "MultiPolygon") |
| `coordinates` | The coordinates defining the GeoJSON object |

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

### Example 1 - Find stores that geographically intersect

For better performance, start with creating the required `2dsphere` index.

```javascript
db.stores.createIndex({ "location": "2dsphere" })
```

The example query find stores that intersect with a specific polygon area using the `stores` collection. This polygon encompasses several store locations from our dataset.

```javascript
db.stores.find(
  {
    location: {
      $geoIntersects: {
        $geometry: {
          type: "Polygon",
          coordinates: [[
            [-80.0, -75.0],
            [-80.0, -70.0],
            [-55.0, -70.0],
            [-55.0, -75.0],
            [-80.0, -75.0]
          ]]
        }
      }
    }
  },
  {
    name: 1,
    location: 1
  }
).limit(2)
```

The query returns stores, whose locations intersect with the Polygon contour defined by the coordinates.

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

The $geointersects operator is useful for the following scenarios:

- Finding stores within a specific geographical boundary
- Identifying service coverage areas
- Planning delivery routes
