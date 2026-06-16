---
title: $trunc
description: The $trunc operator truncates a number to a specified decimal place.
type: operators
category: arithmetic-expression
---

# $trunc

The `$trunc` operator truncates a number to a specified decimal place.

## Syntax

```javascript
{
  $trunc: [ <number>, <decimal place> ]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<number>`** | The number to truncate. |
| **`<decimal place>`** | The decimal place to truncate the specified number to. A positive value truncates to the right of the decimal point, and a negative value truncates to the left of the decimal point. |

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

### Example 1 - Fetch truncated location coordinates

To retrieve the truncated coordinates of stores within the "First Up Consultants" company, first run a query to filter stores by the company name. Then, use the $trunc operator on the latitude and longitude fields to return the desired result.

```javascript
db.stores.aggregate([
  {
    $project: {
      truncatedLat: { $trunc: ["$location.lat", 2] }
    }
  }
])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "name": "First Up Consultants | Bed and Bath Pantry - Port Antone",
        "location": {
            "lat": 87.2239,
            "lon": -129.0506
        },
        "truncatedLatitute": 87,
        "truncatedLongitude": -129
    },
    {
        "_id": "26afb024-53c7-4e94-988c-5eede72277d5",
        "name": "First Up Consultants | Microphone Bazaar - South Lexusland",
        "location": {
            "lat": -29.1866,
            "lon": -112.7858
        },
        "truncatedLatitute": -29,
        "truncatedLongitude": -112
    },
    {
        "_id": "62438f5f-0c56-4a21-8c6c-6bfa479494ad",
        "name": "First Up Consultants | Plumbing Supply Shoppe - New Ubaldofort",
        "location": {
            "lat": -0.2136,
            "lon": 108.7466
        },
        "truncatedLatitute": 0,
        "truncatedLongitude": 108
    }
]
```
