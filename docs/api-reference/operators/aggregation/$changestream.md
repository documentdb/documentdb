---
title: $changeStream
description: The $changeStream stage opens a change stream cursor to track data changes in real-time.
type: operators
category: aggregation
---

# $changeStream

The `$changeStream` aggregation stage opens a change stream cursor that tracks data changes in real-time. This stage enables applications to react to insert, update, delete, and other operations as they occur in the collection.

## Syntax

```javascript
{
  $changeStream: {
    allChangesForCluster: <boolean>,
    fullDocument: <string>,
    fullDocumentBeforeChange: <string>,
    resumeAfter: <ResumeToken>,
    startAfter: <ResumeToken>,
    startAtOperationTime: <Timestamp>,
    showExpandedEvents: <boolean>
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`allChangesForCluster`** | Optional. Boolean. If true, returns changes for the entire cluster. Default is false. |
| **`fullDocument`** | Optional. String. Determines what to return for update operations. Options: 'default', 'updateLookup', 'whenAvailable', 'required'. |
| **`fullDocumentBeforeChange`** | Optional. String. Returns the preimage of the document. Options: "off", "whenAvailable", "required". |
| **`resumeAfter`** | Optional. Resume token to resume change stream after a specific event. |
| **`startAfter`** | Optional. Resume token to start change stream after a specific event. |
| **`startAtOperationTime`** | Optional. timestamp for starting change stream from a specific time. |
| **`showExpandedEvents`** | Optional. Boolean. Include another change stream events. Default is false. |

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

### Example 1: Monitor all changes in stores collection

This operation sets up a change stream to monitor all changes in the stores collection.

```javascript
db.stores.aggregate([
  {
    $changeStream: {
      fullDocument: "updateLookup"
    }
  }
])
```

When a store document is updated, the change stream returns the change event with the full document.

```json
{
  "_id": { "_data": "AeARBpQ/AAAA" },
  "operationType": "update",
  "fullDocument": {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
    "name": "Trey Research | Home Office Depot - Lake Freeda",
    "sales": {
      "revenue": 42500
    },
    "company": "Trey Research",
    "lastUpdated": "ISODate('2024-06-16T10:30:00.000Z')"
  },
  "ns": {
    "db": "StoreData",
    "coll": "stores"
  },
  "documentKey": {
    "_id": "905d1939-e03a-413e-a9c4-221f74055aac"
  }
}
```
