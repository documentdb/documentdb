---
title: $bitsAllSet
description: The bitsAllSet command is used to match documents where all the specified bit positions are set.
type: operators
category: bitwise-query
---

# $bitsAllSet

The `$bitsAllSet` operator is used to match documents where all the specified bit positions are set (that is, are 1). This operator is useful for performing bitwise operations on fields that store integer values. It can be used in scenarios where you need to filter documents based on specific bits being set within an integer field.

## Syntax

```javascript
{
  <field>: { $bitsAllSet: <bitmask> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field in the document on which the bitwise operation is to be performed.|
| **`<bitmask>`** | A bitmask indicating which bits must be set in the field's value.|

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

The `storeFeatures` field is a bitmask integer representing various store capabilities. Each bit corresponds to a feature:

| Bit | Value | Feature                 |
|-----|-------|--------------------------|
| 0   | 1     | In-Store Pickup          |
| 1   | 2     | Parking                  |
| 2   | 4     | Wheelchair Access        |
| 3   | 8     | Open 24 Hours            |
| 4   | 16    | Pet-Friendly             |
| 5   | 32    | Free Wi-Fi               |
| 6   | 64    | Restrooms                |
| 7   | 128   | Home Delivery            |

### Example 1: Find stores that have parking and restrooms

This query retrieves stores that **have parking AND restrooms** (bits 1 and 6)

```javascript
db.stores.find({
    storeFeatures: {
        $bitsAllSet: [1, 6]
    }
}, {
    _id: 1,
    name: 1,
    storeFeatures: 1
}).limit(5)
```

Equivalent:

```javascript
db.stores.find({
    storeFeatures: {
        $bitsAllSet: 66
    }
}, {
    _id: 1,
    name: 1,
    storeFeatures: 1
}).limit(5)
```

The first five results returned by this query are:

```json
[
  {
    "_id": "7e53ca0f-6e24-4177-966c-fe62a11e9af5",
    "name": "Contoso, Ltd. | Office Supply Deals - South Shana",
    "storeFeatures": 86
  },
  {
    "_id": "44fdb9b9-df83-4492-8f71-b6ef648aa312",
    "name": "Fourth Coffee | Storage Solution Gallery - Port Camilla",
    "storeFeatures": 222
  },
  {
    "_id": "728c068a-638c-40af-9172-8ccfa7dddb49",
    "name": "Contoso, Ltd. | Book Store - Lake Myron",
    "storeFeatures": 239
  },
  {
    "_id": "a2b54e5c-36cd-4a73-b547-84e21d91164e",
    "name": "Contoso, Ltd. | Baby Products Corner - Port Jerrold",
    "storeFeatures": 126
  },
  {
    "_id": "dda2a7d2-6984-40cc-bbea-4cbfbc06d8a3",
    "name": "Contoso, Ltd. | Home Improvement Closet - Jaskolskiview",
    "storeFeatures": 107
  }
]
```
