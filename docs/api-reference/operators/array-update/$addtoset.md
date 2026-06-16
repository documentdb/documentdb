---
title: $addToSet
description: The addToSet operator adds elements to an array if they don't already exist, while ensuring uniqueness of elements within the set.
type: operators
category: array-update
---

# $addToSet

The `$addToSet` operator adds elements to an array if they don't already exist, while ensuring uniqueness of elements within the set.

## Syntax

```javascript
{
  $addToSet: { <field1>: <value1> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<field1>`** | The field to which you want to add elements. |
| **`<value1>`** | The value to be added to the array. |

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

### Example 1: Add a new tag to the `tag` array

This query adds a new tag to the array of tags, run a query using the $addToSet operator to add the new value.

```javascript
db.stores.updateOne({
    _id: "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"
}, {
    $addToSet: {
        tag: "#ShopLocal"
    }
})
```

This query returns the following result:

```json
[
  {
    "acknowledged": true,
    "insertedId": null,
    "matchedCount": "1",
    "modifiedCount": "0",
    "upsertedCount": 0
  }
]
```

### Example 2: Adding a new promotional event to the `promotionEvents` array

This query adds a new event to the `promotionEvents` array, run a query using the $addToSet operator with the new promotion object to be added.

```javascript
db.stores.updateOne({
    _id: "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"
}, {
    $addToSet: {
        promotionEvents: {
            eventName: "Summer Sale",
            promotionalDates: {
                startDate: {
                    Year: 2024,
                    Month: 6,
                    Day: 1
                },
                endDate: {
                    Year: 2024,
                    Month: 6,
                    Day: 15
                }
            },
            discounts: [{
                categoryName: "DJ Speakers",
                discountPercentage: 20
            }]
        }
    }
})
```

This query returns the following result:

```json
[
  {
    "acknowledged": true,
    "insertedId": null,
    "matchedCount": "1",
    "modifiedCount": "1",
    "upsertedCount": 0
  }
]
```

### Example 3 - Using $addToSet with $setWindowOperators

To retrieve the list of cities for each store within the "First Up Consultants" company, run a query to first partition stores by the company. Then, use the $addToSet operator to add the distinct cities for each store within the partition.

```javascript
db.stores.aggregate([{
    $match: {
        company: {
            $in: ["First Up Consultants"]
        }
    }
}, {
    $setWindowFields: {
        partitionBy: "$company",
        sortBy: {
            "sales.totalSales": -1
        },
        output: {
            citiesForCompany: {
                $push: "$city",
                window: {
                    documents: ["unbounded", "current"]
                }
            }
        }
    }
}, {
    $project: {
        company: 1,
        name: 1,
        citiesForCompany: 1
    }
}])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "a1713bed-4c8b-46e7-bb68-259045dffdb4",
        "name": "First Up Consultants | Bed and Bath Collection - Jaskolskiside",
        "company": "First Up Consultants",
        "citiesForCompany": [
            "South Thelma",
            "South Carmenview",
            "Port Antone",
            "Charlotteville",
            "South Lenorafort",
            "Jaskolskiside"
        ]
    },
    {
        "_id": "6b8585ab-4357-4da7-8625-f6a1cd5796c5",
        "name": "First Up Consultants | Computer Depot - West Zack",
        "company": "First Up Consultants",
        "citiesForCompany": [
            "South Thelma",
            "South Carmenview",
            "Port Antone",
            "Charlotteville",
            "South Lenorafort",
            "Jaskolskiside",
            "West Zack"
        ]
    }
]
```
