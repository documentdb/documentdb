---
title: $jsonSchema
description: The $jsonSchema operator validates documents against a JSON Schema definition for data validation and structure enforcement. Discover supported features and limitations.
type: operators
category: evaluation-query
---

# $jsonSchema

The `$jsonSchema` operator is used to validate documents against a JSON Schema specification. It ensures that documents conform to a predefined structure, data types, and validation rules.

## Syntax

The syntax for the `$jsonSchema` operator is as follows:

```javascript
db.createCollection("collectionName", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["field1", "field2"],
      properties: {
        field1: {
          bsonType: "string",
          description: "Description of field1 requirements"
        },
        field2: {
          bsonType: "int",
          minimum: 0,
          description: "Description of field2 requirements"
        }
      }
    }
  },
  validationLevel: "strict", // Optional: "strict" or "moderate"
  validationAction: "error"   // Optional: "error" or "warn"
})
```

## Parameters

| Parameter | Description |
| --- | --- |
| **`bsonType`** | Specifies the Binary JSON (BSON) types that the field must match. Accepts string aliases used by the $type operator. |
| **`properties`** | Object defining validation rules for specific fields. |
| **`minimum/maximum`** | Numeric constraints for number fields. |
| **`minLength/maxLength`** | String length constraints. |
| **`minItems/maxItems`** | Array length constraints. |
| **`pattern`** | Regular expression pattern for string validation. |
| **`items`** | Schema validation for array elements. |
| **`uniqueItems`** | Boolean indicating if array items must be unique. |

## Supported Keywords

DocumentDB supports the following JSON Schema keywords:

| Keyword | Type | Description | Usage |
|---------|------|-------------|--------|
| `additionalItems` | arrays | Schema for extra array items | Extended array validation |
| `bsonType` | all types | MongoDB extension - accepts BSON type aliases | `"string"`, `"int"`, `"double"`, `"object"`, `"array"`, `"bool"`, `"date"` |
| `exclusiveMinimum` | numbers | Exclusive minimum boundary | Advanced numeric validation |
| `exclusiveMaximum` | numbers | Exclusive maximum boundary | Advanced numeric validation |
| `items` | arrays | Schema for array elements | Array element validation |
| `minimum` | numbers | Minimum value constraint | Numeric validation |
| `maximum` | numbers | Maximum value constraint | Numeric validation |
| `minItems` | arrays | Minimum array length | Array size validation |
| `maxItems` | arrays | Maximum array length | Array size validation |
| `multipleOf` | numbers | Value must be multiple of specified number | Mathematical constraints |
| `minLength` | strings | Minimum string length | String validation |
| `maxLength` | strings | Maximum string length | String validation |
| `pattern` | strings | Regular expression pattern matching | String format validation |
| `properties` | objects | Define validation rules for object fields | Schema definition for nested objects |
| `required` | objects | Array of required field names | Enforce mandatory fields |
| `type` | all types | Standard JSON Schema types | `"object"`, `"array"`, `"number"`, `"boolean"`, `"string"`, `"null"` |
| `uniqueItems` | arrays | Enforce unique array elements | Data integrity |

### Unsupported Keywords

These JSON Schema keywords are yet to be supported in DocumentDB:

| Keyword | Type | Reason for Non-Support | Workaround |
|---------|------|----------------------|------------|
| `additionalProperties` | objects | Not implemented | Use explicit `properties` definitions |
| `allOf` | all types | Logical operator not supported | Use nested validation |
| `anyOf` | all types | Logical operator not supported | Use separate queries |
| `dependencies` | objects | Complex dependency validation not supported | Handle in application logic |
| `description` | N/A | Might not appear in error messages | Informational only |
| `enum` | all types | Enumeration validation not supported | Use `$in` operator instead |
| `maxProperties` | objects | Property count validation not supported | Handle in application logic |
| `minProperties` | objects | Property count validation not supported | Handle in application logic |
| `not` | all types | Negation operator not supported | Use positive validation rules |
| `oneOf` | all types | Logical operator not supported | Use application-level validation |
| `patternProperties` | objects | Pattern-based property validation not supported | Use explicit property names |
| `title` | N/A | Metadata field not processed | Use `description` instead |

## Examples

Let's explore practical examples using the `stores` dataset:

```json
{
  "_id": "2cf3f885-9962-4b67-a172-aa9039e9ae2f",
  "name": "First Up Consultants | Bed and Bath Center - South Amir",
  "location": {
    "lat": 60.7954,
    "lon": -142.0012
  },
  "staff": {
    "totalStaff": {
      "fullTime": 18,
      "partTime": 17
    }
  },
  "sales": {
    "totalSales": 37701,
    "salesByCategory": [
      {
        "categoryName": "Mattress Toppers",
        "totalSales": 37701
      }
    ]
  }
}
```

### Example 1: Basic Structure Validation

This query retrieves all stores with names between 5 and 100 characters long, and that geographic coordinates fall within valid ranges: latitude between -90 and 90, and longitude between -180 and 180.

```javascript
db.stores.find({
  $jsonSchema: {
    bsonType: "object",
    properties: {
      _id: {
        bsonType: "string"
      },
      name: {
        bsonType: "string",
        minLength: 5,
        maxLength: 100
      },
      location: {
        bsonType: "object",
        properties: {
          lat: {
            bsonType: "double",
            minimum: -90,
            maximum: 90
          },
          lon: {
            bsonType: "double",
            minimum: -180,
            maximum: 180
          }
        }
      }
    }
  }
}).limit(1)

```

### Example 2: Sales Validation with Array Items

This query retrieves all store documents where the sales field is a valid object containing a non-negative totalSales value and a salesByCategory array with at least one item.

```javascript
db.stores.find({
  $jsonSchema: {
    bsonType: "object",
    properties: {
      sales: {
        bsonType: "object",
        properties: {
          totalSales: {
            bsonType: "int",
            minimum: 0
          },
          salesByCategory: {
            bsonType: "array",
            minItems: 1,
            items: {
              bsonType: "object",
              properties: {
                categoryName: {
                  bsonType: "string",
                  minLength: 1
                },
                totalSales: {
                  bsonType: "int",
                  minimum: 0
                }
              }
            }
          }
        }
      }
    }
  }
}).limit(1)

```

This query should return this output:

```javascript
[
  {
    _id: 'new-store-001',
    name: 'Adatum Corporation - Downtown Branch',
    sales: { totalSales: 5000 },
    createdDate: ISODate('2025-06-11T11:11:32.262Z'),
    status: 'new',
    staff: { totalStaff: { fullTime: 0, partTime: 0 } },
    version: 1,
    storeOpeningDate: ISODate('2025-06-11T11:11:32.262Z'),
    storeFeatures: 213
  }
]
```

### Example 3: Combining with Query Operators

This query retrieves all store documents where the staff field is a valid object that includes a totalStaff subobject with at least one full-time staff member (fullTime ≥ 1) and sales.totalSales greater than 10,000.

```javascript
db.stores.find({
  $and: [
    {
      $jsonSchema: {
        properties: {
          staff: {
            bsonType: "object",
            properties: {
              totalStaff: {
                bsonType: "object",
                properties: {
                  fullTime: {
                    bsonType: "int",
                    minimum: 1
                  }
                }
              }
            }
          }
        }
      }
    },
    // Additional query constraints
    {
      "sales.totalSales": { $gt: 10000 }
    }
  ]
}).limit(1)
```

This query returns the following result:

```javascript
[
  {
    _id: 'future-electronics-001',
    address: { city: 'New Tech City' },
    name: 'Boulder Innovations - Future Electronics Hub',
    sales: { totalSales: 25000 },
    establishedDate: ISODate('2025-06-11T11:14:23.147Z'),
    categories: [ 'electronics', 'gadgets', 'smart-home' ],
    promotionEvents: [],
    ratings: { average: 0, count: 0, reviews: [] },
    inventory: {
      lastUpdated: ISODate('2025-06-11T11:14:23.147Z'),
      totalItems: 0,
      lowStockAlerts: []
    },
    storeOpeningDate: ISODate('2025-06-11T11:11:32.262Z'),
    storeFeatures: 120
  }
]
```
