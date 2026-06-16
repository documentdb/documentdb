---
title: $in
description: The $in operator matches value of a field against an array of specified values
type: operators
category: comparison-query
---

# $in

The `$in` operator matches values of a field against an array of possible values. The `$in` operator filters documents where the value of a field equals any of the specified values.

## Syntax

```javascript
{
    field: {
        $in: [ listOfValues ]
    }
}
```

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

### Example 1 - Use $in operator as comparison-query to find a store with specific categories of promotions

This query finds stores that offer discounts in either "Smoked Salmon" or "Anklets" categories via promotion events.

```javascript
db.stores.find({
    "promotionEvents.discounts.categoryName": {
        $in: ["Smoked Salmon", "Anklets"]
    }
}, {
    name: 1,
    "promotionEvents.discounts.categoryName": 1
}).limit(1)
```

The first result returned by this query is:

```json
[
    {
      "_id": "48fcdab8-b961-480e-87a9-19ad880e9a0a",
      "name": "Lakeshore Retail | Jewelry Collection - South Nicholas",
      "promotionEvents": [
        {
          "discounts": [
            {"categoryName": "Anklets"},
            {"categoryName": "Cufflinks"}
          ]
        },
        {
          "discounts": [
            {"categoryName": "Anklets"},
            {"categoryName": "Brooches"}
          ]
        },
        {
          "discounts": [
            {"categoryName": "Rings"},
            {"categoryName": "Bracelets"}
          ]
        },
        {
          "discounts": [
            {"categoryName": "Charms"},
            {"categoryName": "Bracelets"}
          ]
        },
        {
          "discounts": [
            {"categoryName": "Watches"},
            {"categoryName": "Pendants"}
          ]
        }
      ]
    }
]
```

### Example 2 - Use $in operator as array-expression in an array for a specified value or set of values

This query searches for the specified store and filters documents where at least one `discountPercentage` within any `promotionEvents.discounts` is either 15 or 20. It uses a dot notation path and the $in operator to match nested discount values across the array hierarchy.

```javascript
db.stores.find({
    _id: "48fcdab8-b961-480e-87a9-19ad880e9a0a",
    "promotionEvents.discounts.discountPercentage": {
        $in: [15, 20]
    }
}, {
    _id: 1,
    name: 1,
    "promotionEvents.discounts": 1
})
```

This query returns the following result:

```json
[
    {
      "_id": "48fcdab8-b961-480e-87a9-19ad880e9a0a",
      "name": "Lakeshore Retail | Jewelry Collection - South Nicholas",
      "promotionEvents": [
        {
          "discounts": [
            { "categoryName": "Anklets", "discountPercentage": 12 },
            { "categoryName": "Cufflinks", "discountPercentage": 9 }
          ]
        },
        {
          "discounts": [
            { "categoryName": "Anklets", "discountPercentage": 23 },
            { "categoryName": "Brooches", "discountPercentage": 12 }
          ]
        },
        {
          "discounts": [
            { "categoryName": "Rings", "discountPercentage": 10 },
            { "categoryName": "Bracelets", "discountPercentage": 21 }
          ]
        },
        {
          "discounts": [
            { "categoryName": "Charms", "discountPercentage": 9 },
            { "categoryName": "Bracelets", "discountPercentage": 13 }
          ]
        },
        {
          "discounts": [
            { "categoryName": "Watches", "discountPercentage": 20 },
            { "categoryName": "Pendants", "discountPercentage": 7 }
          ]
        }
      ]
    }
]
```
