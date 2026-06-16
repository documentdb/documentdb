---
title: $sample
description: The $sample operator in DocumentDB returns a randomly selected number of documents
type: operators
category: aggregation
---

# $sample

The `$sample` stage is used in aggregation pipelines to randomly select a specified number of documents from a collection. The `$sample` command is useful during testing, data analysis, and generating random subsets of data for machine learning.

## Syntax

```javascript
{
  $sample: { size: <number> }
}
```

### Parameters

| Parameter | Description |
| --- | --- |
| **`size`** | The number of documents to randomly select from the collection|

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

### Example 1 - Randomly select five documents and project the corresponding document IDs

```javascript
 db.stores.aggregate([{
     $sample: {
         size: 5
     }
 }, {
     $project: {
         _id: 1
     }
 }])
```

This query returns the following results:

```json
[
  { "_id": "f7ae8b40-0c66-4e80-9261-ab31bbabffb4" },
  { "_id": "25350272-6797-4f98-91f8-fe79084755c7" },
  { "_id": "c7fd1d22-1a29-4cb0-9155-1ad71d600c2b" },
  { "_id": "e602b444-9519-42e3-a2e1-b5a3da5f6e64" },
  { "_id": "189c239a-edca-434b-baae-aada3a27a2c5" }
]
```
