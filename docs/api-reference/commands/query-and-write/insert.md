---
title: insert
description: The insert command in DocumentDB creates new documents in a collection
type: commands
category: query-and-write
---

# insert

The `insert` command is used to create new documents into a collection. Either a single document or multiple documents can be inserted in one go.

## Syntax

The basic syntax of the insert command is:

```javascript
db.collection.insert(
   <single document or array of documents>,
   {
     writeConcern: <document>,
     ordered: <boolean>
   }
)
```

### Parameters

| Parameter | Description |
| --- | --- |
| **`<single document or array of documents>`** | The document or array of documents to insert into the collection|
| **`writeConcern`** | (Optional) A document expressing the write concern. The write concern describes the level of acknowledgment requested from the server for the write operation|
| **`ordered`** | (Optional) If `true`, the server inserts the documents in the order provided. If `false`, the server can insert the documents in any order and will attempt to insert all documents regardless of errors|

- `<single document or array of documents>`: The document or array of documents to insert into the collection.
- `writeConcern`: Optional. A document expressing the write concern. The write concern describes the level of acknowledgment requested from the server for the write operation.
- `ordered`: Optional. If `true`, the server inserts the documents in the order provided. If `false`, the server can insert the documents in any order and will attempt to insert all documents regardless of errors.

## Example(s)

### Inserting a single document

The following command inserts a single document into the stores collection in the StoreData database.

```javascript
db.stores.insertOne({
  "storeId": "12345",
  "name": "Boulder Innovations",
  "location": {
    "lat": 37.7749,
    "lon": -122.4194
  },
  "staff": {
    "totalStaff": {
      "fullTime": 15,
      "partTime": 10
    }
  },
  "sales": {
    "totalSales": 500000.00,
    "salesByCategory": [
      {
        "categoryName": "Laptops",
        "totalSales": 300000.00
      },
      {
        "categoryName": "Smartphones",
        "totalSales": 200000.00
      }
    ]
  },
  "promotionEvents": [
    {
      "eventName": "Summer Sale",
      "promotionalDates": {
        "startDate": "2024-06-01",
        "endDate": "2024-06-30"
      },
      "discounts": [
        {
          "categoryName": "Laptops",
          "discountPercentage": 15
        },
        {
          "categoryName": "Smartphones",
          "discountPercentage": 10
        }
      ]
    },
    {
      "eventName": "Holiday Specials",
      "promotionalDates": {
        "startDate": "2024-12-01",
        "endDate": "2024-12-31"
      },
      "discounts": [
        {
          "categoryName": "Laptops",
          "discountPercentage": 20
        },
        {
          "categoryName": "Smartphones",
          "discountPercentage": 25
        }
      ]
    }
  ]
})
```

### Inserting multiple documents

The following command inserts an array of documents into the stores collection.

```javascript
db.stores.insertMany([
  {
    "storeId": "12346",
    "name": "Graphic Design Institute",
    "location": {
      "lat": 34.0522,
      "lon": -118.2437
    },
    "staff": {
      "totalStaff": {
        "fullTime": 20,
        "partTime": 5
      }
    },
    "sales": {
      "totalSales": 750000.00,
      "salesByCategory": [
        {
          "categoryName": "Laptops",
          "totalSales": 400000.00
        },
        {
          "categoryName": "Smartphones",
          "totalSales": 350000.00
        }
      ]
    },
    "promotionEvents": [
      {
        "eventName": "Black Friday",
        "promotionalDates": {
          "startDate": "2024-11-25",
          "endDate": "2024-11-30"
        },
        "discounts": [
          {
            "categoryName": "Laptops",
            "discountPercentage": 25
          },
          {
            "categoryName": "Smartphones",
            "discountPercentage": 30
          }
        ]
      }
    ]
  },
  {
    "storeId": "12347",
    "name": "Relecloud",
    "location": {
      "lat": 40.7128,
      "lon": -74.0060
    },
    "staff": {
      "totalStaff": {
        "fullTime": 10,
        "partTime": 20
      }
    },
    "sales": {
      "totalSales": 600000.00,
      "salesByCategory": [
        {
          "categoryName": "Laptops",
          "totalSales": 350000.00
        },
        {
          "categoryName": "Smartphones",
          "totalSales": 250000.00
        }
      ]
    },
    "promotionEvents": [
      {
        "eventName": "New Year Sale",
        "promotionalDates": {
          "startDate": "2024-01-01",
          "endDate": "2024-01-07"
        },
        "discounts": [
          {
            "categoryName": "Laptops",
            "discountPercentage": 10
          },
          {
            "categoryName": "Smartphones",
            "discountPercentage": 15
          }
        ]
      }
    ]
  }
])
```

### Specifying a value for the _id field

If the _id field is not specified, the server auto generates a unique ObjectId() value for the document. If the document does specify the _id field, it must be a globally unique value across all documents within the collection.

If a duplicate value for the _id field is specified, a duplicate key violation error will be thrown by the server.

```json
{
    "WriteErrors": [
        {
            "WriteError": {
                "err": {
                    "index": 0,
                    "code": 11000,
                    "errmsg": "Duplicate key violation on the requested collection: Index '_id_'",
                    "errInfo": "undefined",
                    "op": {
                        "testField": "testValue",
                        "_id": "1"
                    }
                }
            }
        }
    ]
}
```

### Inserting multiple documents in order

Documents that are inserted in bulk can be inserted in order when specifying "ordered": true

```javascript
db.stores.insertMany([
  {
    "_id": "123456",
    "storeId": "123456",
    "name": "Graphic Design Institute",
    "location": {
      "lat": 34.0522,
      "lon": -118.2437
    },
    "staff": {
      "totalStaff": {
        "fullTime": 20,
        "partTime": 5
      }
    },
    "sales": {
      "totalSales": 750000.00,
      "salesByCategory": [
        {
          "categoryName": "Laptops",
          "totalSales": 400000.00
        },
        {
          "categoryName": "Smartphones",
          "totalSales": 350000.00
        }
      ]
    },
    "promotionEvents": [
      {
        "eventName": "Black Friday",
        "promotionalDates": {
          "startDate": "2024-11-25",
          "endDate": "2024-11-30"
        },
        "discounts": [
          {
            "categoryName": "Laptops",
            "discountPercentage": 25
          },
          {
            "categoryName": "Smartphones",
            "discountPercentage": 30
          }
        ]
      }
    ]
  },
  {
    "_id": "234567",
    "storeId": "234567",
    "name": "Relecloud",
    "location": {
      "lat": 40.7128,
      "lon": -74.0060
    },
    "staff": {
      "totalStaff": {
        "fullTime": 10,
        "partTime": 20
      }
    },
    "sales": {
      "totalSales": 600000.00,
      "salesByCategory": [
        {
          "categoryName": "Laptops",
          "totalSales": 350000.00
        },
        {
          "categoryName": "Smartphones",
          "totalSales": 250000.00
        }
      ]
    },
    "promotionEvents": [
      {
        "eventName": "New Year Sale",
        "promotionalDates": {
          "startDate": "2024-01-01",
          "endDate": "2024-01-07"
        },
        "discounts": [
          {
            "categoryName": "Laptops",
            "discountPercentage": 10
          },
          {
            "categoryName": "Smartphones",
            "discountPercentage": 15
          }
        ]
      }
    ]
  }
], "ordered": true)
```

The ordered insert command returns a response confirming the order in which documents were inserted:

```json
{
    "acknowledged": true,
    "insertedIds": {
        "0": "123456",
        "1": "234567"
    }
}
```

## Related content

- [update with DocumentDB](update)
- [find with DocumentDB](find)
