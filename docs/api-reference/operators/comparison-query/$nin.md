---
title: $nin
description: The $nin operator retrieves documents where the value of a field doesn't match a list of values
type: operators
category: comparison-query
---

# $nin

The `$nin` operator retrieves documents where the value of a specified field doesn't match a list of values.

## Syntax

```javascript
{
    field: {
        $nin: [ < listOfValues > ]
    }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to compare|
| **`[<listOfValues>]`** | An array of values that shouldn't match the value of the field being compared|

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

### Example 1 - Find a store with a discount that isn't 10%, 15%, or 20%

To find a store with promotions offering discounts that are not 10%, 15%, or 20%, first run a query using $nin on the nested discountPercentage field. Then project only the name and discount offered by the result store and limit the result to a single document from the result set.

```javascript
db.stores.find({
    "promotionEvents.discounts.discountPercentage": {
        $nin: [10, 15, 20]
    }
}, {
    name: 1,
    "promotionEvents.discounts.discountPercentage": 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "promotionEvents": [
          {
            "discounts": [
              { "discountPercentage": 18 },
              { "discountPercentage": 17 },
              { "discountPercentage": 9 },
              { "discountPercentage": 5 },
              { "discountPercentage": 5 },
              { "discountPercentage": 6 },
              { "discountPercentage": 9 },
              { "discountPercentage": 5 },
              { "discountPercentage": 19 },
              { "discountPercentage": 21 }
            ]
          }
        ]
    }
]
```

### Example 2 - Find a store with no discounts on specific categories of promotions

To find a store without promotions on Smoked Salmon and Anklets, first run a query using $nin on the nested categoryName field. Then project the name and promotions offered by the store and limit the results to one document from the result set.

```javascript
db.stores.find({
    "promotionEvents.discounts.categoryName": {
        $nin: ["Smoked Salmon", "Anklets"]
    }
}, {
    name: 1,
    "promotionEvents.discounts.categoryName": 1
}, {
    limit: 1
})
```

The first result returned by this query is:

```json
[
    {
        "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
        "name": "First Up Consultants | Bed and Bath Center - South Amir",
        "promotionEvents": [
          {
            "discounts": [
              { "categoryName": "Bath Accessories" },
              { "categoryName": "Pillow Top Mattresses" },
              { "categoryName": "Bathroom Scales" },
              { "categoryName": "Towels" },
              { "categoryName": "Bathrobes" },
              { "categoryName": "Mattress Toppers" },
              { "categoryName": "Hand Towels" },
              { "categoryName": "Shower Heads" },
              { "categoryName": "Bedspreads" },
              { "categoryName": "Bath Mats" }
            ]
          }
        ]
    }
]
```
