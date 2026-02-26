# `$jsonSchema` in DocumentDB

The `$jsonSchema` operator matches documents that satisfy a JSON Schema definition.

## Syntax

```javascript
{ $jsonSchema: <schema-object> }
```

The schema object follows draft-4 style validation semantics supported by the extension.

## Where It Can Be Used

### In Collection Validators

```sql
SELECT documentdb_api.create_collection('documentdb', 'students');

SELECT documentdb_api.coll_mod(
  'documentdb',
  'students',
  '{
    "collMod": "students",
    "validator": {
      "$jsonSchema": {
        "bsonType": "object",
        "required": ["name", "major", "year"],
        "properties": {
          "name": { "bsonType": "string" },
          "major": { "bsonType": "string" },
          "year": { "bsonType": "int", "minimum": 2017, "maximum": 3017 }
        }
      }
    }
  }'
);
```

### In Queries

```sql
SELECT document
FROM bson_aggregation_find(
  'documentdb',
  '{
    "find": "students",
    "filter": {
      "$jsonSchema": {
        "required": ["name"],
        "properties": {
          "name": { "bsonType": "string" }
        }
      }
    }
  }'
);
```

## Current Status

Current implementation supports `$jsonSchema` with a subset of draft-4 keywords.
This section is the source of truth for what works today and what remains to be implemented.

### ✅ Implemented Keywords

- Object: `properties`, `required`
- Common: `type`, `bsonType`, `description`
- String: `maxLength`, `minLength`, `pattern`
- Numeric: `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`, `multipleOf`
- Array: `items`, `additionalItems`, `maxItems`, `minItems`, `uniqueItems`

### ❌ Not Implemented Yet

Keywords outside the implemented set currently fail as unknown `$jsonSchema` keywords.

Key missing items include:

- Object-related: `maxProperties`, `minProperties`, `patternProperties`, `additionalProperties`, `dependencies`
- Composition/common: `enum`, `allOf`, `anyOf`, `oneOf`, `not`
- Metadata: `title`

### ❌ Explicitly Rejected Keywords

The parser currently rejects these with a dedicated "not supported" error:

- `$ref`
- `$schema`
- `default`
- `definitions`
- `format`
- `id`

## Example: Find Non-Compliant Documents

Use `$nor` with the same schema to locate documents that fail the rules:

```sql
SELECT document
FROM bson_aggregation_find(
  'documentdb',
  '{
    "find": "inventory",
    "filter": {
      "$nor": [
        {
          "$jsonSchema": {
            "required": ["item", "qty", "instock"],
            "properties": {
              "item": { "bsonType": "string" },
              "qty": { "bsonType": "int" },
              "instock": { "bsonType": "bool" }
            }
          }
        }
      ]
    }
  }'
);
```

## Internal Implementation Summary

### Why a Tree Model

- A field can carry multiple constraints (`bsonType`, range, string constraints, etc.).
- The schema is normalized into a tree so validators are grouped by field.
- Compiled schema state is reusable across many documents.

### Node Model

- Field node: represents a concrete field and its direct validators.
- Keyword node: represents structural keywords (`properties`, `items`, `additionalItems`, etc.).
- Root node: top-level schema node for document-level checks.

### Validation Flow

Validation traverses BSON in depth-first order:

1. Read a field from the input BSON document.
2. Resolve schema by `properties`.
3. Apply validators attached to the matched schema node.
4. Recurse for nested objects/arrays.

### Performance Notes

- Schema parse and normalization is the expensive step; this is cached.
- Runtime path focuses on BSON traversal plus node checks.
- Reusing compiled schema state reduces repeated parse overhead on write-heavy workloads.

## Contributor Backlog

Open implementation gaps and contribution opportunities are tracked in [schema_validation.md](schema_validation.md#limitations-and-future-work).

## Implementation Notes

- Validation is evaluated against BSON documents directly.
- Compiled evaluation state can be reused for repeated checks with the same schema, reducing per-document overhead.
- `validationAction: warn` currently skips schema validation on write paths.