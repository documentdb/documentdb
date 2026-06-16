---
title: $toBool
description: The $toBool operator converts an expression into a Boolean type
type: operators
category: aggregation
---

# $toBool

The `$toBool` operator converts an expression into a Boolean value. Boolean values are returned as is without a conversion. Nonzero numeric values are converted to true while Decimal, Long, Double or Int values of 0 are converted to false. All other data types are converted to true.

## Syntax

```javascript
{
    $toBool: < expression >
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`expression`** | The specified value to convert into a Boolean value|

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

### Example 1: Convert a Double value into a Boolean value

To convert the value of the latitude field from a double to a boolean, run a query using the $toBool operator on the field to make the conversion. Positive numeric values are converted to true.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalLatitude: "$location.lat",
        latitudeAsBool: {
            $toBool: "$location.lat"
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
        "latitudeAsBool": true
    }
]
```

### Example 2: Convert a String value into a Boolean value

To convert the value of the _id field from a string to a boolean, run a query using the $toBool value to make the conversion. String values are converted to true.

```javascript
 db.stores.aggregate([{
     $match: {
         _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
     }
 }, {
     $project: {
         originalId: "$_id",
         idAsBool: {
             $toBool: "$_id"
         }
     }
 }])
```

This query returns the following result:

```json
[
    {
        "_id": "b0107631-9370-4acd-aafa-8ac3511e623d",
        "originalId": "b0107631-9370-4acd-aafa-8ac3511e623d",
        "idAsBool": true
    }
]
```

### Example 3: Convert an Int value into a Boolean value

To convert the value of the sales.totalSales field from integer to boolean, run a query using the $toBool operator to make the conversion. Positive numeric values are converted to true.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "b0107631-9370-4acd-aafa-8ac3511e623d"
    }
}, {
    $project: {
        originalTotalSales: "$sales.totalSales",
        totalSalesAsBool: {
            $toBool: "$sales.totalSales"
        }
    }
}])
```

This query returns the following result:

```json
[
    {
        "_id": "b0107631-9370-4acd-aafa-8ac3511e623d",
        "originalTotalSales": 9366,
        "totalSalesAsBool": true
    }
]
```

This table delineates the expected behavior of the $toBool operator based on the data type of the input expression.

| **Value Type**                                               | **Behavior/Output** |
|--------------------------------------------------------------|---------------------|
| Boolean value true                                           | Output -> true      |
| Boolean value false                                          | Output -> false     |
| Any Double, Int, Long, or Decimal value                       | Output -> true      |
| Any ISODate value                                            | Output -> true      |
| Null value                                                   | Output -> null      |
