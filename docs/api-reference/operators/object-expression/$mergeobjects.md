---
title: $mergeObjects
description: The $mergeObjects operator merges multiple documents into a single document
type: operators
category: object-expression
---

# $mergeObjects

The `$mergeObjects` operator combines multiple documents into a single document. The mergeObjects operation is used in aggregation pipelines to merge fields from different documents or add one or more fields to an existing document. The operator overwrites fields in the target document with fields from the source document when conflicts occur.

## Syntax

```javascript
{
  $mergeObjects: [ < document1 > , < document2 > , ...]
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`document1, document2`** | The documents to be merged. The documents can be specified as field paths, subdocuments, or constants. |

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

### Example 1 - Merging documents as an accumulator to group documents by the sales subdocument

The query merges all sales subdocuments per city for a specific company.

```javascript
db.stores.aggregate([
  {
    $match: {
      company: "Fourth Coffee"
    }
  },
  {
    $group: {
      _id: "$city",
      mergedSales: {
        $mergeObjects: "$sales"
      }
    }
  },
  {
    $limit: 2   // returns only the first 3 grouped cities
  }
])
```

The first two results returned by this query are:

```json
[
  {
      "_id": "Jalonborough",
      "mergedSales": {
          "totalSales": 45747,
          "salesByCategory": [
              {
                  "categoryName": "Bucket Bags",
                  "totalSales": 45747
              }
          ]
      }
  },
  {
      "_id": "Port Vladimir",
      "mergedSales": {
          "totalSales": 32000,
          "salesByCategory": [
              {
                  "categoryName": "DJ Speakers",
                  "totalSales": 24989
              },
              {
                  "categoryName": "DJ Cables",
                  "totalSales": 7011
              }
          ]
      }
  }
]
```
