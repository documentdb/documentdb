---
title: $centerSphere
description: The $centerSphere operator specifies a circle using spherical geometry for $geoWithin queries.
type: operators
category: geospatial
---

# $centerSphere

The `$centerSphere` operator specifies a circle using spherical geometry for `$geoWithin` queries. This operator is useful for geographic calculations that need to account for Earth's spherical shape.

## Syntax

```javascript
{
  $geoWithin: {
    $centerSphere: [ [ <x>, <y> ], <radius in radians> ]
  }
}
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `<x>` | The longitude of the circle's center point |
| `<y>` | The latitude of the circle's center point |
| `<radius in radians>` | The radius of the sphere in radians (divide distance in kilometers by 6371 to convert to radians) |

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

### Example 1: Find stores within a circular area (calculation over earth's spherical shape)

The example query finds two stores within approximately 1,000 kilometers (radius ≈ 0.157 radians) of the Wide World Importers Headphone Corner store location. The query can help identify nearby stores for regional marketing campaigns or supply chain optimization.

```javascript
// Convert 1000km to radians: 1000/6371 ≈ 0.157
db.stores.find(
  {
    location: {
      $geoWithin: {
        $centerSphere: [[-82.5543, -65.105], 0.157]
      }
    }
  },
  {
    _id: 0,
    name: 1,
    location: 1,
    city: 1
  }
).limit(2)
```

The first two results returned by this query are:

```json
[
  {
    "name": "Fourth Coffee | Electronics Bazaar - O'Keefeburgh",
    "location": { "lat": -64.5856, "lon": -115.5241 },
    "city": "O'Keefeburgh"
  },
  {
    "name": "Boulder Innovations | Footwear Outlet - West Sybleberg",
    "location": { "lat": -72.73, "lon": -60.2306 },
    "city": "West Sybleberg"
  }
]
```

> [!IMPORTANT]
> The `$centerSphere` operator calculates distances using spherical geometry, making it more accurate for Earth-based calculations than `$center`.
> 
> The radius must be specified in radians.
> 
> Coordinates should be specified in the order: [longitude, latitude].
> 
> If the geographic buffer extends beyond a UTM zone or crosses the international dateline, the results may be inaccurate or unpredictable.
