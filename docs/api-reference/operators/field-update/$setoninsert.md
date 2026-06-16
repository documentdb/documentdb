---
title: $setOnInsert
description: The $setOnInsert operator sets field values only when an upsert operation results in an insert of a new document.
type: operators
category: field-update
---

# $setOnInsert

The `$setOnInsert` operator is used to set field values only when an upsert operation results in the insertion of a new document. If the document already exists and is being updated, the `$setOnInsert` operator has no effect. This operator is particularly useful for setting default values or initialization data that should only be applied when creating new documents.

## Syntax

```javascript
{
  $setOnInsert: {
    <field1>: <value1>,
    <field2>: <value2>,
    ...
  }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The name of the field to set only on insert. Can be a top-level field or use dot notation for nested fields. |
| **`value`** | The value to assign to the field only when inserting a new document. Can be any valid BSON type. |

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

### Example 1: Basic $setOnInsert usage

To create or update a store record, but only set certain initialization fields when creating a new store.

```javascript
db.stores.updateOne(
  { "_id": "new-store-001" },
  {
    $set: {
      "name": "Trey Research Electronics - Downtown",
      "sales.totalSales": 0
    },
    $setOnInsert: {
      "createdDate": new Date(),
      "status": "new",
      "staff.totalStaff.fullTime": 0,
      "staff.totalStaff.partTime": 0,
      "version": 1
    }
  },
  { upsert: true }
)
```

This operation returns the following result.

```json
{
  acknowledged: true,
  insertedId: 'new-store-001',
  matchedCount: 0,
  modifiedCount: Long("0"),
  upsertedCount: 1
}
```

Since the document with `_id: "new-store-001"` doesn't exist, this operation creates the following new document:

```json
{
  "_id": "new-store-001",
  "name": "Trey Research Electronics - Downtown",
  "sales": {
    "totalSales": 0
  },
  "createdDate": ISODate("2025-06-05T10:30:00.000Z"),
  "status": "new",
  "staff": {
    "totalStaff": {
      "fullTime": 0,
      "partTime": 0
    }
  },
  "version": 1
}
```

### Example 2: $setOnInsert with existing document

Now, let's try to upsert the same document again with different values:

```javascript
db.stores.updateOne(
  { "_id": "new-store-001" },
  {
    $set: {
      "name": "Trey Research Electronics - Downtown Branch",
      "sales.totalSales": 5000
    },
    $setOnInsert: {
      "createdDate": new Date(),
      "status": "updated",
      "staff.totalStaff.fullTime": 10,
      "staff.totalStaff.partTime": 5,
      "version": 2
    }
  },
  { upsert: true }
)
```

Since the document already exists, only the `$set` operations will be applied, and `$setOnInsert` will be ignored:

```json
{
  "_id": "new-store-001",
  "name": "Trey Research Electronics - Downtown Branch",
  "sales": {
    "totalSales": 5000
  },
  "createdDate": ISODate("2025-06-05T10:30:00.000Z"),
  "status": "new",
  "staff": {
    "totalStaff": {
      "fullTime": 0,
      "partTime": 0
    }
  },
  "version": 1
}
```

### Example 3: Complex $setOnInsert with nested objects

You can use `$setOnInsert` to initialize complex nested structures:

```javascript
db.stores.updateOne(
  { "name": "Adatum Gaming Paradise - Mall Location" },
  {
    $set: {
      "location.lat": 35.6762,
      "location.lon": 139.6503
    },
    $setOnInsert: {
      "_id": "gaming-store-mall-001",
      "createdDate": new Date(),
      "status": "active",
      "staff": {
        "totalStaff": {
          "fullTime": 8,
          "partTime": 12
        },
        "manager": "Alex Johnson",
        "departments": ["gaming", "accessories", "repairs"]
      },
      "sales": {
        "totalSales": 0,
        "salesByCategory": []
      },
      "operatingHours": {
        "weekdays": "10:00-22:00",
        "weekends": "09:00-23:00"
      },
      "metadata": {
        "version": 1,
        "source": "store-management-system"
      }
    }
  },
  { upsert: true }
)
```

### Example 4: Using $setOnInsert with arrays

You can initialize arrays and complex data structures:

```javascript
db.stores.updateOne(
  { "address.city": "New Tech City" },
  {
    $set: {
      "name": "Future Electronics Hub",
      "sales.totalSales": 25000
    },
    $setOnInsert: {
      "_id": "future-electronics-001",
      "establishedDate": new Date(),
      "categories": ["electronics", "gadgets", "smart-home"],
      "promotionEvents": [],
      "ratings": {
        average: 0,
        count: 0,
        reviews: []
      },
      "inventory": {
        lastUpdated: new Date(),
        totalItems: 0,
        lowStockAlerts: []
      }
    }
  },
  { upsert: true }
)
```

> [!Important]
> 
> The `$setOnInsert` operator only takes effect during upsert operations (`{ upsert: true }`).
> 
> If the document exists, `$setOnInsert` fields are completely ignored.
> 
> `$setOnInsert` is commonly used with `$set` to handle both update and insert scenarios in a single operation.
> 
> You can combine `$setOnInsert` with other update operators like `$inc`, `$push`, etc.
> 
> The `$setOnInsert` operator is ideal for setting creation timestamps, default values, and initialization data.
