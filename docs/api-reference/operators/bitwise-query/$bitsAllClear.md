---
title: $bitsAllClear
description: The $bitsAllClear operator is used to match documents where all the bit positions specified in a bitmask are clear.
type: operators
category: bitwise-query
---

# $bitsAllClear

The `$bitsAllClear` operator is used to match documents where all the bit positions specified in a bitmask are clear (that is, 0). This operator is useful in scenarios where you need to filter documents based on specific bits being unset in a binary representation of a field.

## Syntax

```javascript
{
  <field>: { $bitsAllClear: <bitmask> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field in the document on which the bitwise operation is to be performed.|
| **`<bitmask>`** | A bitmask where each bit position specifies the corresponding bit position in the field's value that must be clear (0).|

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

### Example 1: Find stores that are not open 24 hours and do not allow pets

This query retrieves stores that are NOT open 24 hours AND do NOT allow pets (bits 3 and 4)

```javascript
db.stores.find({
    storeFeatures: {
        $bitsAllClear: [3, 4]
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
            $bitsAnySet: 24
        }
    }, // 8 + 16
    {
        _id: 1,
        name: 1,
        storeFeatures: 1
    }).limit(5)
```

The first five results returned by this query are:

```json
[
  {
    "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
    "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort",
    "storeFeatures": 38
  },
  {
    "_id": "94792a4c-4b03-466b-91f6-821c4a8b2aa4",
    "name": "Fourth Coffee | Eyewear Shop - Lessiemouth",
    "storeFeatures": 225
  },
  {
    "_id": "1a2c387b-bb43-4b14-a6cd-cc05a5dbfbd5",
    "name": "Contoso, Ltd. | Smart Home Device Vault - Port Katarina",
    "storeFeatures": 36
  },
  {
    "_id": "e88f0096-4299-4944-9788-695c40786d97",
    "name": "Adatum Corporation | Handbag Shoppe - Lucienneberg",
    "storeFeatures": 135
  },
  {
    "_id": "bfb213fa-8db8-419f-8e5b-e7096120bad2",
    "name": "First Up Consultants | Beauty Product Shop - Hansenton",
    "storeFeatures": 135
  }
]
```
