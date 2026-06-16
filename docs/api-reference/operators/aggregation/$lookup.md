---
title: $lookup
description: The $lookup stage in the Aggregation Framework is used to perform left outer joins with other collections.
type: operators
category: aggregation
---

# $lookup

The `$lookup` stage in the Aggregation Framework is used to perform left outer joins with other collections. It allows you to combine documents from different collections based on a specified condition. This operator is useful for enriching documents with related data from other collections without having to perform multiple queries.

## Syntax

```javascript
{
  $lookup: {
    from: <collection to join>,
    localField: <field from input documents>,
    foreignField: <field from the documents of the "from" collection>,
    as: <output array field>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`from`** | The name of the collection to join with.|
| **`localField`** | The field from the input documents that are matched with the `foreignField`.|
| **`foreignField`** | The field from the documents in the `from` collection that are matched with the `localField`.|
| **`as`** | The name of the new array field to add to the input documents. This array contains the matched documents from the `from` collection.|

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

Let's say we have another `ratings` collection with two documents.

```json
{
  "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
  "rating": 5
}
{
  "_id": "fecca713-35b6-44fb-898d-85232c62db2f",
  "rating": 3
}
```

### Example 1: Combine two collections to list promotion events for stores with a rating of 5

This query joins the `ratings` collection with the `stores` collection to list promotion events related to each store having a 5 rating.

```javascript
db.ratings.aggregate([
  // filter based on rating in ratings collection
  {
    $match: {
      "rating": 5
    }
  },
  // find related documents in stores collection
  {
    $lookup: {
      from: "stores",
      localField: "_id",
      foreignField: "_id",
      as: "storeEvents"
    }
  },
  // deconstruct array to output a document for each element of the array
  {
    $unwind: "$storeEvents"
  },
   // Include only _id and name fields in the output 
  { $project: { _id: 1, "storeEvents.name": 1 } }  

])
```

This query returns the following result:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "storeEvents": { "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile" }
  }
]
```

### Example 2: Joining two collections (ratings and stores) using a variable from ratings.

```javascript
db.ratings.aggregate([
  {
    $match: { rating: 5 }
  },
  {
    $lookup: {
      from: "stores",
      let: { id: "$_id" },
      pipeline: [
        {
          $match: {
            $expr: { $eq: ["$_id", "$$id"] }
          }
        },
        {
          $project: { _id: 0, name: 1 }
        }
      ],
      as: "storeInfo"
    }
  },
  {
    $unwind: "$storeInfo"
  },
  {
    $project: {
      _id: 1,
      rating: 1,
      "storeInfo.name": 1
    }
  }
])
```

This query returns the following result:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "rating": 5,
        "storeInfo": {
            "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile"
        }
    }
]
```
