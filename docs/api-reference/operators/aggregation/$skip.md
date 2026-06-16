---
title: $skip
description: The $skip stage in the aggregation pipeline is used to skip a specified number of documents from the input and pass the remaining documents to the next stage in the pipeline.
type: operators
category: aggregation
---

# $skip

The $skip stage in the aggregation pipeline is used to skip a specified number of documents from the input and pass the remaining documents to the next stage in the pipeline. The stage is useful for implementing pagination in queries and for controlling the subset of documents that subsequent stages in the pipeline operate on.

## Syntax

```javascript
{
  $skip: <number>
}
```

### Parameters

| Parameter | Description |
| --- | --- |
| **`number`** | The number of documents to skip before passing the remaining documents to the next stage. |

## Examples

Consider this sample document from the stores collection.

```json
{
    _id: '0fcc0bf0-ed18-4ab8-b558-9848e18058f4',
    name: 'First Up Consultants | Beverage Shop - Satterfieldmouth',
    location: { lat: -89.2384, lon: -46.4012 },
    staff: { employeeCount: { fullTime: 2, partTime: 20 } },
    sales: {
      salesByCategory: [
        { categoryName: 'Wine Accessories', totalSales: 34450 },
        { categoryName: 'Bitters', totalSales: 39496 },
        { categoryName: 'Rum', totalSales: 1734 }
      ],
      revenue: 75670
    },
    promotionEvents: [
      {
        eventName: 'Unbeatable Bargain Bash',
        promotionalDates: {
          startDate: { Year: 2024, Month: 6, Day: 23 },
          endDate: { Year: 2024, Month: 7, Day: 2 }
        },
        discounts: [
          { categoryName: 'Whiskey', discountPercentage: 7 },
          { categoryName: 'Bitters', discountPercentage: 15 },
          { categoryName: 'Brandy', discountPercentage: 8 },
          { categoryName: 'Sports Drinks', discountPercentage: 22 },
          { categoryName: 'Vodka', discountPercentage: 19 }
        ]
      },
      {
        eventName: 'Steal of a Deal Days',
        promotionalDates: {
          startDate: { Year: 2024, Month: 9, Day: 21 },
          endDate: { Year: 2024, Month: 9, Day: 29 }
        },
        discounts: [
          { categoryName: 'Organic Wine', discountPercentage: 19 },
          { categoryName: 'White Wine', discountPercentage: 20 },
          { categoryName: 'Sparkling Wine', discountPercentage: 19 },
          { categoryName: 'Whiskey', discountPercentage: 17 },
          { categoryName: 'Vodka', discountPercentage: 23 }
        ]
      },
      {
        eventName: 'Summer Sale',
        promotionalDates: {
          startDate: { Year: 2024, Month: 6, Day: 1 },
          endDate: { Year: 2024, Month: 6, Day: 15 }
        },
        discounts: [ { categoryName: 'DJ Speakers', discountPercentage: 20 } ]
      }
    ],
    company: 'First Up Consultants',
    city: 'Satterfieldmouth',
    storeOpeningDate: ISODate("2024-09-20T18:28:57.302Z"),
    lastUpdated: Timestamp({ t: 1729448937, i: 1 }),
    store: { promotionEvents: null },
    tag: [ '#ShopLocal' ]
  }
```

### Example 1: Skipping documents in a collection

To skip the first 2 documents and return the rest, you can use the following aggregation pipeline:

```javascript
db.stores.aggregate([
  { $skip: 2 }
])
```

The first two results returned by this query are:

```json
[
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c5",
    "store": {
      "name": "Downtown Store",
      "promotionEvents": ["Summer Sale", "Black Friday", "Holiday Deals"]
    }
  },
  {
    "_id": "7954bd5c-9ac2-4c10-bb7a-2b79bd0963c6",
    "store": {
      "name": "Uptown Store",
      "promotionEvents": ["Back to School", "Winter Sale"]
    }
  }
]
```

### Example 2: Skipping documents and then limiting the result

To skip the first 2 documents and then limit the result to the next 3 documents, you can combine $skip with $limit:

```javascript
db.stores.aggregate([
  { $skip: 2 },
  { $limit: 3 }
])
```

The first two results returned by this query are:

```json
[
    {
        "_id": "728c068a-638c-40af-9172-8ccfa7dddb49",
        "name": "Contoso, Ltd. | Book Store - Lake Myron",
        "location": {
            "lat": 29.416,
            "lon": 21.5231
        },
        "staff": {
            "employeeCount": {
                "fullTime": 7,
                "partTime": 16
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Science Fiction",
                    "totalSales": 34879
                }
            ],
            "revenue": 34879
        },
        "promotionEvents": [
            {
                "eventName": "Blowout Bonanza",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 9,
                        "Day": 21
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 9,
                        "Day": 30
                    }
                },
                "discounts": [
                    {
                        "categoryName": "Children's Books",
                        "discountPercentage": 11
                    },
                    {
                        "categoryName": "Fiction",
                        "discountPercentage": 21
                    }
                ]
            }
        ],
        "company": "Contoso, Ltd.",
        "city": "Lake Myron",
        "storeOpeningDate": "ISODate('2024-09-28T18:23:21.591Z')",
        "lastUpdated": "Timestamp({ t: 1730139801, i: 1 })",
        "storeFeatures": 239
    },
    {
        "_id": "44fdb9b9-df83-4492-8f71-b6ef648aa312",
        "name": "Fourth Coffee | Storage Solution Gallery - Port Camilla",
        "location": {
            "lat": 78.3889,
            "lon": 0.6784
        },
        "staff": {
            "employeeCount": {
                "fullTime": 17,
                "partTime": 15
            }
        },
        "sales": {
            "salesByCategory": [
                {
                    "categoryName": "Storage Boxes",
                    "totalSales": 2236
                }
            ],
            "revenue": 2236
        },
        "promotionEvents": [
            {
                "eventName": "Major Discount Mania",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 6,
                        "Day": 23
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 7,
                        "Day": 3
                    }
                },
                "discounts": [
                    {
                        "categoryName": "Bathroom Storage",
                        "discountPercentage": 19
                    },
                    {
                        "categoryName": "Kitchen Storage",
                        "discountPercentage": 10
                    }
                ]
            },
            {
                "eventName": "Flash Deal Frenzy",
                "promotionalDates": {
                    "startDate": {
                        "Year": 2024,
                        "Month": 9,
                        "Day": 21
                    },
                    "endDate": {
                        "Year": 2024,
                        "Month": 9,
                        "Day": 30
                    }
                },
                "discounts": [
                    {
                        "categoryName": "Under-Bed Storage",
                        "discountPercentage": 20
                    },
                    {
                        "categoryName": "Closet Organizers",
                        "discountPercentage": 21
                    }
                ]
            }
        ],
        "company": "Fourth Coffee",
        "city": "Port Camilla",
        "storeOpeningDate": "ISODate('2024-09-23T06:02:53.844Z')",
        "lastUpdated": "Timestamp({ t: 1729663373, i: 1 })",
        "storeFeatures": 222
    }
]
```

### Example 3: Skipping documents in a complex pipeline

To skip the first promotion event and then project the remaining events for a specific store:

```javascript
db.stores.aggregate([
  { $match: { "_id": "0fcc0bf0-ed18-4ab8-b558-9848e18058f4", } },
  { $unwind: "$promotionEvents" },
  { $skip: 1 },
  { $project: { "promotionEvents": 1, _id: 0 } }
])
```

The first two results returned by this query are:

```json
[
    {
        "promotionEvents": {
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
    },
    {
        "promotionEvents": {
            "eventName": "Summer Sale",
            "promotionalDates": {
                "startDate": {
                    "Year": 2024,
                    "Month": 6,
                    "Day": 1
                },
                "endDate": {
                    "Year": 2024,
                    "Month": 6,
                    "Day": 15
                }
            },
            "discounts": [
                {
                    "categoryName": "DJ Speakers",
                    "discountPercentage": 20
                }
            ]
        }
    }
]
```
