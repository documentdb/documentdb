---
title: $type
description: The $type operator retrieves documents if the chosen field is of the specified type.
type: operators
category: element-query
---

# $type

The `$type` operator retrieves documents if a chosen field is of the specified type. The $type operator is useful in data validation and ensuring consistency across documents in a collection.

## Syntax

```javascript
{
  <field>: { $type: <BSON type number> | <string alias> }
}
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`field`** | The field to check the type of. |
| **`BSON type number`** | A number corresponding to the BSON type (e.g., 1 for double, 2 for string). |
| **`string alias`** | A string alias for the BSON type (e.g., "double", "string", "object", "array"). |

## Common BSON Types

| Type | Number | Alias | Description |
| --- | --- | --- | --- |
| Double | 1 | "double" | 64-bit floating point |
| String | 2 | "string" | UTF-8 string |
| Object | 3 | "object" | Embedded document |
| Array | 4 | "array" | Array |
| ObjectId | 7 | "objectId" | ObjectId |
| Boolean | 8 | "bool" | Boolean |
| Date | 9 | "date" | Date |
| Null | 10 | "null" | Null value |
| 32-bit integer | 16 | "int" | 32-bit integer |
| Timestamp | 17 | "timestamp" | Timestamp |
| 64-bit integer | 18 | "long" | 64-bit integer |

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

### Example 1: Find stores with string-type names

To find any store whose name is of type string, run a query using the $type operator on the name field. Then, project only the ID and name fields and limit the results to one document from the result set.

```javascript
db.stores.find({
    "name": {
        $type: "string"
    }
}, {
    "_id": 1,
    "name": 1
}).limit(1)
```

This query returns the following result:

```json
[
    {
        "_id": "a715ab0f-4c6e-4e9d-a812-f2fab11ce0b6",
        "name": "Lakeshore Retail | Holiday Supply Hub - Marvinfort"
    }
]
```

### Example 2: Data validation using multiple type checks

This query demonstrates how to validate that essential fields in the collection's document structure have the desired data types.

```javascript
db.stores.find({
      "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
      "name": {
          $type: "string"
      },
      "location": {
          $type: "object"
      },
      "staff.employeeCount.fullTime": {
          $type: ["int", "long"]
      },
      "promotionEvents": {
          $type: "array"
      }
  }, {
      "_id": 1,
      "name": 1,
      "location": 1,
      "staff": 1
  }
)
```

This query returns the following result.

```json
[
    {
        "_id": "905d1939-e03a-413e-a9c4-221f74055aac",
        "name": "Trey Research | Home Office Depot - Lake Freeda",
        "location": {
            "lat": -48.9752,
            "lon": -141.6816
        },
        "staff": {
            "employeeCount": {
                "fullTime": 12
            }
        }
    }
]
```
