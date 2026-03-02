---
rfc: 0006
title: "Schema Validation for DocumentDB Collections"
status: Complete
owner: "@jiahu2"
issue: ""
discussion: ""
---

# RFC-0006: Schema Validation

## Problem

DocumentDB users need to enforce document structure constraints to ensure data quality and application reliability. 
## Overview

Schema validation enforces document structure constraints at write time. The implementation supports:
- `$jsonSchema` validators (JSON Schema Draft 4)
- Query-expression validators (`$expr`, MongoDB query operators)
- Mixed validators (combination of both)
- Validation levels (`strict`, `moderate`, `off`) and actions (`error`, `warn`)
- Integration with insert/update paths and aggregation write stages (`$merge`, `$out`)

## Current State

**Implemented:**
- ✅ Basic `$jsonSchema` validation
- ✅ Query-expression based validators (e.g., `$expr`)
- ✅ Mixed validators (combination of `$jsonSchema` and query expressions)
- ✅ `validationLevel`: `off`, `strict`, `moderate`
- ✅ `validationAction`: `error` (full), `warn` (partial)
- ✅ `bypassDocumentValidation` support
- ✅ Validation on aggregation write stages (`$merge`, `$out`)
- ✅ Schema metadata persistence in collection metadata
- ✅ `collMod` support for updating validation rules

**Known Limitations:**
- ⚠️ `validationAction: warn`: Currently skips validation instead of logging warnings
- ⚠️ Generic error messages: "Document failed validation" (no field path or constraint details)
- ⚠️ DDL-time validation: Only `$jsonSchema` syntax validated; query expressions not pre-validated

**Missing JSON Schema Keywords:**
- Composition: `enum`, `allOf`, `anyOf`, `oneOf`, `not`
- Object: `additionalProperties`, `patternProperties`, `maxProperties`, `minProperties`, `dependencies`
- Metadata: `title`

---

## Architecture

### Component Overview

Schema validation spans three layers:

**1. Metadata Storage** (`pg_documentdb_core`)
- Collection metadata table columns: `validator` (BSON), `validation_level` (text), `validation_action` (text)
- Validator stored as BSON document; supports any form (`$jsonSchema`, `$expr`, mixed)

**2. Validation Engine** (`pg_documentdb`)
- Compiles validators to PostgreSQL `ExprEvalState` for unified execution
- `$jsonSchema`: Uses tree-based model for efficient field-path matching
- Query expressions: Reuses existing `$expr` and operator infrastructure
- Cached compilation: Validator compiled once per collection, reused across document validations

**3. Write Path Enforcement**
- Insert/update hooks: `ValidateFinalPgbsonBeforeWriting()`
- Aggregation stages: `$merge`/`$out` validate target collection documents
- Bypass support: `bypassDocumentValidation` flag skips validation

---

## Implementation Details

### Metadata Schema

```sql
ALTER TABLE collections
  ADD COLUMN validator bson DEFAULT null,
  ADD COLUMN validation_level text DEFAULT 'strict',
  ADD COLUMN validation_action text DEFAULT 'error';
```

### Supported `$jsonSchema` Keywords

**Implemented:**
- Object: `properties`, `required`
- Common: `type`, `bsonType`, `description`
- String: `maxLength`, `minLength`, `pattern`
- Numeric: `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`, `multipleOf`
- Array: `items`, `additionalItems`, `maxItems`, `minItems`, `uniqueItems`

**Not Implemented** (fail with "unknown keyword" error at DDL time):
- See "Missing JSON Schema Keywords" in Current State section

### Validation Levels

- **`strict`**: All inserts and updates must satisfy validator
- **`moderate`**: Inserts validated; updates only validated if pre-update document was valid
- **`off`**: Validation disabled

### Validation Actions

- **`error`**: Reject write if validation fails
- **`warn`**: Currently skips validation (intended: log warnings and allow write)

### Validation Execution Flow

**Entry Point**: `ValidateFinalPgbsonBeforeWriting()` called from insert/update paths

**Steps:**

1. **Load metadata**: Retrieve `validator`, `validationLevel`, `validationAction` from collection metadata
2. **Early exit checks**:
   - Skip if `validationAction != "error"` (warn currently not implemented)
   - Skip if `validationLevel == "off"`
   - Skip if `bypassDocumentValidation == true`
3. **Compile validator** (cached):
   - `GetExpressionEvalStateForBsonInput()` → `CreateQualForBsonExpression()`
   - Converts validator BSON to PostgreSQL `ExprEvalState`
   - Supports any validator form (`$jsonSchema`, `$expr`, mixed)
4. **Evaluate document**:
   - `EvalBooleanExpressionAgainstBson(evalState, document)`
   - Returns true (pass) or false (fail)
5. **Handle result**:
   - Pass: Proceed with write
   - Fail: `ereport(ERROR, ERRCODE_DOCUMENTDB_DOCUMENTFAILEDVALIDATION)`

**Moderate level special handling**: 
- On update: If new document fails validation, check old document
- Only reject if old document was valid (prevents breaking existing invalid docs)

### `$jsonSchema` Tree Model

**Design Rationale**: Fields can have multiple validators (type, range, string length, etc.). Tree structure groups validators by field path for efficient evaluation.

**Node Types**:
- `SchemaNode`: Base structure with `validationFlags` and `validations` union
- `SchemaFieldNode`: Represents concrete field (e.g., `properties.name`)
- `SchemaKeywordNode`: Structural keywords (`properties`, `items`, `additionalItems`)

**Validation Process**:
1. Parse `$jsonSchema` → Build tree via `BuildSchemaTree()`
2. Traverse BSON document depth-first
3. Match field paths → Apply validators (fail-fast on first error)
4. Return boolean result

**Example**: `{"year": 2025}` vs `{"properties": {"year": {"bsonType": "int", "minimum": 2017}}}`
→ Match `year` → Check `bsonType: int` → Check `minimum: 2017` → Pass

### Performance Optimizations

- **Compilation caching**: Validator compiled once per collection, stored in `ExprEvalState`, reused across all validations
- **Fail-fast**: Exit on first constraint violation (no need to collect all errors)
- **Direct BSON evaluation**: No intermediate conversions or copies
- **Field path indexing**: O(1) schema node lookup via hash tables
- **Memory management**: Compiled state in PostgreSQL memory context, shared across sessions, freed on collection drop

### API Changes

**Modified functions:**

1. **`documentdb_api.create_collection_view()`** - Extended to accept validation options:
   ```sql
   SELECT documentdb_api.create_collection_view('test_db', 
     '{ "create": "users", 
        "validator": {"$jsonSchema": {"bsonType": "object", "required": ["email"]}},
        "validationLevel": "strict",
        "validationAction": "error"
     }');
   ```
   
   **Parameters added to spec BSON:**
   - `validator` (bson): Validation expression (`$jsonSchema`, `$expr`, or mixed)
   - `validationLevel` (string): `"off"` | `"strict"` | `"moderate"`
   - `validationAction` (string): `"error"` | `"warn"`

2. **`documentdb_api.coll_mod()`** - Support updating validation rules:
   ```sql
   SELECT documentdb_api.coll_mod('test_db', 'users',
     '{"collMod": "users",
       "validator": {"$jsonSchema": {"bsonType": "object"}},
       "validationLevel": "moderate",
       "validationAction": "warn"
     }');
   ```

3. **Write operations** - Internal support for `bypassDocumentValidation` flag
   - Passed through command spec BSON in insert/update/aggregate commands
   - Checked in `CheckSchemaValidationEnabled()` before validation

### Testing Coverage

**Regression tests:**
- `schema_validation.sql` / `schema_validation.out`
- `schema_validation_insert.sql` / `schema_validation_insert.out`
- `bson_dollar_ops_json_schema_build_tree_tests.sql`

**Test coverage includes:**
- Basic `$jsonSchema` validation scenarios
- Mixed validators (`$jsonSchema` + query expressions)
- Validation levels and actions
- Bypass functionality
- Aggregation write stages with validation
- `collMod` updates to validation rules
- Tree model construction and normalization
- Individual validator keyword tests (numeric, string, array, object)

---

## Future Work

The following areas need completion for full MongoDB compatibility:

### 1. Missing `$jsonSchema` Validators

- `enum`: Value must be in specified list
- `additionalProperties`: Control whether extra properties are allowed
- `patternProperties`: Properties matching regex pattern must satisfy schema
- `allOf`: Document must satisfy all schemas
- `anyOf`: Document must satisfy at least one schema
- `oneOf`: Document must satisfy exactly one schema
- `not`: Document must not satisfy schema
- `maxProperties`, `minProperties`: Object property count constraints
- `dependencies`: Property dependencies
- `title`: Documentation metadata

**Implementation guidance:**
- Add new validator types to `$jsonSchema` tree builder
- Implement evaluation logic in validation engine
- Add comprehensive test coverage for each validator

### 2. Validation Error Diagnostics

**Current state:** Generic "Document failed validation" error

**Needed:**
- Field path of failing constraint
- Rule/keyword that failed
- Expected vs actual value
- Hierarchical error details for nested schemas

**Example desired output:**
```
Document failed validation:
  Field: "year"
  Rule: maximum
  Expected: <= 3017
  Actual: 4000
```

**Implementation guidance:**
- Extend error context in validation engine
- Propagate detailed error information through write path
- Format user-friendly error messages

### 3. Schema Pre-validation Coverage

**Current state:** Pre-validation focuses on `$jsonSchema` syntax

**Needed:**
- Validate non-`$jsonSchema` query expressions at DDL time
- Catch invalid validator expressions before storage
- Provide clear error messages for malformed validators

**Implementation guidance:**
- Extend DDL-time validation to cover all validator forms
- Test various malformed validator expressions
- Document which constructs are validated at create/collMod time

---

## How to Contribute

### Getting Started

1. **Understand the architecture:**
   - Read [Architecture](#architecture) and [Implementation Details](#implementation-details) in this RFC
   - Understand the tree-based schema model for `$jsonSchema`
   - Study the validation execution flow
   - Examine test files: `schema_validation*.sql` and `bson_dollar_ops_json_schema_build_tree_tests.sql`

2. **Find the code:**
   - Schema tree builder: `pg_documentdb/src/jsonschema/bson_json_schema_tree.c`
   - Validator evaluation: `pg_documentdb/src/jsonschema/bson_json_schema_validator.c`
   - Write path integration: `pg_documentdb/src/schema_validation/schema_validation.c`
   - Metadata handling: `pg_documentdb/src/metadata/collection.c`

3. **Development workflow:**
   - For new `$jsonSchema` keywords:
     a. Add keyword handling in `BuildSchemaTreeCoreOnNode()` (tree builder)
     b. Implement validator logic in `ValidateBsonValue*()` functions
     c. Add tests to `bson_dollar_ops_json_schema_build_tree_tests.sql`
     d. Verify MongoDB compatibility
   - For error diagnostics:
     a. Extend `ValidateBsonValueAgainstSchemaTree()` to collect failure context
     b. Propagate error details through `ValidateSchemaOnDocument*()` functions
    c. Format error message in write path hooks
   - Update this RFC with implementation status

4. **Testing:**
   - Run regression tests: `make installcheck`
   - Compare behavior with MongoDB for compatibility
   - Test edge cases (nested schemas, array validation, type coercion)
   - Benchmark performance with large documents/complex schemas