---
title: $toInt
description: The $toInt operator converts an expression into an Integer
type: operators
category: aggregation
---

# $toInt

The `$toInt` operator converts a specified value into an integer value.

## Syntax

The syntax for the `$toInt` operator is:

```javascript
{
    $toInt: < expression >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | The specified value to convert into an Integer value|

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

### Example 1: Convert a Double value into an Integer value

To convert the value of the latitude field from a double to an int, run a query using the $toInt operator on the field to make the conversion.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalLatitude: "$location.lat",
        latitudeAsInt: {
            $toInt: "$location.lat"
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
        "latitudeAsInt": 72
    }
]
```

### Example 2: Convert a String value into an Integer value

To convert the string representation of 72 ("72") to an integer value, run a query using the $toInt operator on the value to make the conversion.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalLatitude: "$location.lat",
        latitudeAsInt: {
            $toInt: {
                $toString: "72"
            }
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
        "latitudeAsInt": 72
    }
]
```

However, the following query returns an error since the string "72.0" isn't the string representation of an integer value.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalLatitude: "$location.lat",
        latitudeAsInt: {
            $toInt: {
                $toString: "72.0"
            }
        }
    }
}])
```

This query returns the following error message - "Failed to parse number '72.0' in $convert"

This table delineates the expected behavior of the $toInt operator based on the data type of the input.

| **Value Type**                                               | **Behavior/Output** |
|--------------------------------------------------------------|---------------------|
| Boolean value true                                           | Output -> 1         |
| Boolean value false                                          | Output -> 0         |
| Double value. E.g., 72.0                                     | Output -> 72        |
| String representation of an integer value. For example, "72" | Output -> 72        |
| String representation of a double value. For example, "72.0" | Output -> Error     |
| Null value                                                   | Output -> null      |
