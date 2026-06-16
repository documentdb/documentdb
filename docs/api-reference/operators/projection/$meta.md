---
title: $meta
description: The $meta operator returns a calculated metadata column with returned dataset.
type: operators
category: projection
---

# $meta

The `$meta` projection operator is used to include metadata in the results of a query. It's useful for including metadata such as text search scores or other computed values in the output documents.

## Syntax

The syntax for using the `$meta` projection operator is as follows:

```javascript
db.collection.find({
    $text: {
        $search: < string >
    }
}, {
    field: {
        $meta: < metaDataKeyword >
    }
})
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field in the output documents where the metadata gets included. |
| **`metaDataKeyword`** | The type of metadata to include common keywords like `textScore` for text search scores. |

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "34f462fe-5085-4a77-a3de-53f4117466bd",
  "name": "Wide World Importers",
  "location": {
    "lat": -63.5435,
    "lon": 77.7226
  },
  "staff": {
    "totalStaff": {
      "fullTime": 16,
      "partTime": 16
    }
  },
  "sales": {
    "totalSales": 41481,
    "salesByCategory": [
      {
        "categoryName": "Holiday Tableware",
        "totalSales": 41481
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Crazy Deal Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2023,
          "Month": 11,
          "Day": 13
        },
        "endDate": {
          "Year": 2023,
          "Month": 11,
          "Day": 22
        }
      },
      "discounts": [
        {
          "categoryName": "Gift Boxes",
          "discountPercentage": 9
        },
        {
          "categoryName": "Holiday Tableware",
          "discountPercentage": 24
        }
      ]
    },
    {
      "eventName": "Incredible Savings Showcase",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 5,
          "Day": 11
        },
        "endDate": {
          "Year": 2024,
          "Month": 5,
          "Day": 20
        }
      },
      "discounts": [
        {
          "categoryName": "Ribbons",
          "discountPercentage": 15
        },
        {
          "categoryName": "Gift Bags",
          "discountPercentage": 25
        }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#FashionStore",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}

```

### Example 1: Including text search scores

To include the text search score in the results of a text search query.

```javascript
db.stores.createIndex({ "name": "text"});

db.stores.find(
    { $text: { $search: "Equipment Furniture Finds" } },
    { _id: 1, name: 1, score: { $meta: "textScore" } }
).sort({ score: { $meta: "textScore" } }).limit(2)

```

The first two results returned by this query are:

```json
[
  {
    _id: 'cf1448e9-5493-49b5-95da-ab8a105b5240',
    name: 'Tailwind Traders | Camera Market - Wolfmouth',
    score: 4
  },
  {
    _id: '4fd389af-4693-4c02-93cf-0d80ae8ace07',
    name: 'Wide World Importers | Camera Collection - South Cordelia',
    score: 4
  }
]
```

## Limitation

- If no index is used, the { $meta: "indexKey" } doesn't return anything.
