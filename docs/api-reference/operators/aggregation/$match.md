---
title: $match
description: The $match stage in the aggregation pipeline is used to filter documents that match a specified condition.
type: operators
category: aggregation
---

# $match

The `$match` stage in the aggregation pipeline is used to filter documents that match a specified condition. It's similar to the `find` operation but is used within the aggregation pipeline to narrow down the documents that pass through to the next stage. This stage is highly useful for optimizing performance by reducing the number of documents that need to be processed in subsequent stages.

## Syntax

```javascript
{
  $match: {
    <query>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`<query>`**| A standard MongoDB query document that specifies the conditions that the documents must meet.|

## Examples

Consider this sample document from the stores collection.

```json
{
  "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
   "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
  "location": {
    "lat": 60.1441,
    "lon": -141.5012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 2,
      "partTime": 0
    }
  },
  "sales": {
    "salesByCategory": [
      {
        "categoryName": "DJ Headphones",
        "totalSales": 35921
      }
    ],
    "fullSales": 3700
  },
  "promotionEvents": [
    {
      "eventName": "Bargain Blitz Days",
      "promotionalDates": {
        "startDate": {
          "Year": 2024,
          "Month": 3,
          "Day": 11
        },
        "endDate": {
          "Year": 2024,
          "Month": 2,
          "Day": 18
        }
      },
      "discounts": [
        {
          "categoryName": "DJ Turntables",
          "discountPercentage": 18
        },
        {
          "categoryName": "DJ Mixers",
          "discountPercentage": 15
        }
      ]
    }
  ],
  "tag": [
    "#ShopLocal",
    "#SeasonalSale",
    "#FreeShipping",
    "#MembershipDeals"
  ]
}
```

### Example 1: Match documents using string comparison

This query retrieves documents where the `_id` is "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5":

```javascript
db.stores.aggregate([
    {
      $match: {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5"
      }
    }
])
```

This query returns the following result:

```json
[
    {
        "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
        "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile",
        "location": {
            "lat": 60.1441,
            "lon": -141.5012
        },
        "staff": {
            "employeeCount": {
                "fullTime": 2,
                "partTime": 0
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "DJ Headphones",
                    "totalSales": 35921
                },
                {
                    "categoryName": "DJ Cables",
                    "totalSales": 1000
                }
            ],
            "fullSales": 3700
        },
        "promotionEvents": [],
        "tag": [
            "#ShopLocal",
            "#NewArrival",
            "#NewArrival",
            "#FreeShipping"
        ],
        "company": "Lakeshore Retail",
        "city": "Port Cecile",
        "lastUpdated": "2025-08-04T05:57:04.619Z",
        "storeOpeningDate": "2024-09-12T10:21:58.274Z"
    }
]
```

### Example 2: Match documents using numeric comparison

This query retrieves all stores where the total sales are greater than $35,000:

```javascript
db.stores.aggregate([
    {
      $match: {
        "sales.totalSales": { $gt: 35000 }
      }
    },
    // Limit the result to the first 3 documents
    { $limit: 3 },
      // Include only _id and name fields in the output 
    { $project: { _id: 1, name: 1 } } 
])
```

The first three results returned by this query are:

```json
[
  {
    "_id": "8345de34-73ec-4a99-9cb6-a81f7b145c34",
    "name": "Northwind Traders | Bed and Bath Place - West Oraland"
  },
  {
    "_id": "57cc4095-77d9-4345-af20-f8ead9ef0197",
    "name": "Wide World Importers | Bed and Bath Store - West Vitafort"
  },
  {
    "_id": "560099f8-325f-4c35-a4e5-2e0879eb95af",
    "name": "Wide World Importers | Bed and Bath Depot - North Maritzaberg"
  }
]
```

### Example 3: Match documents within sub documents

This query retrieves all stores with a discount of 15% on DJ Mixers:

```javascript
db.stores.aggregate([
    {
      $match: {
        "promotionEvents.discounts": {
          $elemMatch: {
            "categoryName": "DJ Mixers",
            "discountPercentage": 15
          }
        }
      }
    },
    // Limit the result to the first 3 documents
    { $limit: 3 },
      // Include only _id and name fields in the output 
    { $project: { _id: 1, name: 1 } } 
])
```

The first three results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "name": "Lakeshore Retail | DJ Equipment Stop - Port Cecile"
  },
  {
    "_id": "3c7eda41-23a1-4226-abf6-17ee9e851b5b",
    "name": "Boulder Innovations | DJ Equipment Bazaar - New Ceasarview"
  },
  {
    "_id": "63831a7d-13a9-4d8b-bf1d-ac004057f96d",
    "name": "Contoso, Ltd. | DJ Equipment Shop - Reillyfurt"
  }
]
```
