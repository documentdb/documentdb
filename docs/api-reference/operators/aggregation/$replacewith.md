---
title: $replaceWith
description: The $replaceWith operator in DocumentDB returns a document after replacing a document with the specified document
type: operators
category: aggregation
---

# $replaceWith

The `$replaceWith` aggregation stage operator is used to replace the input document with the specified document. The `$replaceWith` operator transforms documents from one structure to another or replaces them entirely with new fields and values.

## Syntax

```javascript
{
  "$replaceWith": <newDocument>
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`newDocument`** | The new document to replace the original document|

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

### Example 1 - Return a document that replaces the contents of the original document with a subset of items

First, match a specific document to replace by the _id field and replace the contents of the document with the specified fields.

```javascript
db.stores.aggregate([{
    $match: {
        _id: "bda56164-954d-4f47-a230-ecf64b317b43"
    }
}, {
    $replaceWith: {
        _id: "$_id",
        name: "$name",
        sales: "$sales.totalSales"
    }
}])
```

This query returns the following result:

```json
[
  {
      "_id": "bda56164-954d-4f47-a230-ecf64b317b43",
      "name": "Boulder Innovations | Home Security Place - Ankundingburgh",
      "sales": 37015
  }
]
```

### Example 2 - Return a document that replaces the contents of the original document after aggregating specified fields

```javascript
db.stores.aggregate([{
    $match: {
        _id: "bda56164-954d-4f47-a230-ecf64b317b43"
    }
}, {
    $replaceWith: {
        _id: "$_id",
        name: "$name",
        totalStaff: {
            $add: ["$staff.totalStaff.fullTime", "$staff.totalStaff.partTime"]
        }
    }
}])
```

This returns the following result:

```json
[
  {
      "_id": "bda56164-954d-4f47-a230-ecf64b317b43",
      "name": "Boulder Innovations | Home Security Place - Ankundingburgh",
      "totalStaff": 29
  }
]
```
