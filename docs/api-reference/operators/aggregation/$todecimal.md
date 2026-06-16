---
title: $toDecimal
description: The $toDecimal operator converts an expression into a Decimal type
type: operators
category: aggregation
---

# $toDecimal

The `$toDecimal` operator converts an input expression into a Decimal value. Long, Double or Int values are simply converted to a Decimal data type, while Decimal values are returned as is. A boolean value of true is converted to 1, while a boolean false is converted to 0. Lastly, ISODates are converted to a Decimal value corresponding to the number of milliseconds since January 1st, 1970 represented by the ISODate value.

## Syntax

```javascript
{
    $toDecimal: < expression >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | The specified value to convert into a Decimal value|

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

### Example 1: Convert a Double value into a Decimal value

To convert the value of the latitude field from a double to a decimal value, run a query using the $toDecimal operator to make the conversion.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalLatitude: "$location.lat",
        latitudeAsDecimal: {
            $toDecimal: "$location.lat"
        }
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": "b0107631-9370-4acd-aafa-8ac3511e623d",
        "originalLatitude": 72.8377,
        "latitudeAsDecimal": "Decimal128('72.8377000000000')"
    }
]
```

### Example 2: Convert an ISODate value into a Decimal value

To convert an ISODate to a decimal value, run a query using the $toDecimal operator on the value to make the conversion.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        dateAsDecimal: {
            $toDecimal: ISODate("2025-01-06T00:00:00.000Z")
        }
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": "b0107631-9370-4acd-aafa-8ac3511e623d",
        "dateAsDecimal": "Decimal128('1736121600000')"
    }
]
```
