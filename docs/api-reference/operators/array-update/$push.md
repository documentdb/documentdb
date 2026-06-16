---
title: $push
description: The $push operator adds a specified value to an array within a document.
type: operators
category: array-update
---

# $push

The `$push` operator is used to add a specified value to an array within a document. The $push operator adds new elements to an existing array without affecting other elements in the array.

## Syntax

```javascript
db.collection.update({
    < query >
}, {
    $push: {
        < field >: < value >
    }
}, {
    < options >
})
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<query>`**| The selection criteria for the documents to update.|
| **`<field>`**| The array field to which the value will be appended.|
| **`<value>`**| The value to append to the array field.|
| **`<options>`**| Optional. Additional options for the update operation.|

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

### Example 1 - Add a new sales category

To add a new sales category to the salesByCategory array, run a query using the $push operator on the field with a new Sales object with the name of the category and its sales volume.

```javascript
db.stores.update({
    _id: "0fcc0bf0-ed18-4ab8-b558-9848e18058f4"
}, {
    $push: {
        "sales.salesByCategory": {
            categoryName: "Wine Accessories",
            totalSales: 1000.00
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

### Example 2 - Using $push with $setWindowFields

To retrieve the distinct sales volumes across all stores under the "First Up Consultants" company, first run a query to partition stores within the company. Then, use the $push operator to create a list of sales from the first to the current store within the partition.

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
            salesByStore: {
                $push: "$sales.totalSales",
                window: {
                    documents: ["unbounded", "current"]
                }
            }
        }
    }
}, {
    $project: {
        company: 1,
        salesByStore: 1
    }
}])
```

The first three results returned by this query are:

```json
[
    {
        "_id": "a0386810-b6f8-4b05-9d60-e536fb2b0026",
        "company": "First Up Consultants",
        "salesByStore": [
            327583
        ]
    },
    {
        "_id": "ad8af64a-d5bb-4162-9bb6-e5104126566d",
        "company": "First Up Consultants",
        "salesByStore": [
            327583,
            288582
        ]
    },
    {
        "_id": "39acb3aa-f350-41cb-9279-9e34c004415a",
        "company": "First Up Consultants",
        "salesByStore": [
            327583,
            288582,
            279183
        ]
    }
]
```
