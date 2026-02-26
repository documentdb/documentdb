# Schema Validation

Schema validation defines rules that BSON documents must satisfy during writes.
Validation is configured on a collection and enforced on insert/update paths, including aggregation write stages (`$merge`, `$out`).

## What You Can Configure

Schema rules are set in collection metadata and can include:

- `validator` (query expression and/or `$jsonSchema`)
- `validationAction`: `error` (default) or `warn`
- `validationLevel`: `off`, `strict` (default), or `moderate`

Common SQL flow:

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
				"required": ["name", "year"],
				"properties": {
					"name": { "bsonType": "string" },
					"year": { "bsonType": "int", "minimum": 2017, "maximum": 3017 }
				}
			}
		},
		"validationAction": "error",
		"validationLevel": "strict"
	}'
);

SELECT documentdb_api.coll_mod(
	'documentdb',
	'students',
	'{
		"collMod": "students",
		"validationAction": "warn",
		"validationLevel": "moderate"
	}'
);
```

## Validation Semantics

### When Validation Runs

- On new writes (insert/update) after validation is configured.
- For `moderate`, updates that produce an invalid target document may still succeed if the pre-update document was already invalid.
- For `off`, schema validation is disabled.

### `validationAction`

- `error`: reject the write if validation fails.
- `warn`: current implementation skips schema validation checks for the write path.

### `validationLevel`

- `off`: disable schema validation.
- `strict`: all inserts and updates must satisfy validator rules.
- `moderate`: inserts are validated; for updates, if an update results in a document that violates the schema, the pre-update document must be evaluated. If the original document was already invalid, the update is permitted.

### Bypass Option

Per operation, validation can be bypassed with `bypassDocumentValidation: true` where supported by command semantics.

```sql
SET documentdb.enableBypassDocumentValidation = on;

SELECT documentdb_api.insert(
	'documentdb',
	'{
		"insert": "students",
		"documents": [{"name": "Alice", "year": 2016, "gpa": 3}],
		"bypassDocumentValidation": true
	}'
);

SET documentdb.enableBypassDocumentValidation = off;
```

## Validator Forms

A validator can be:

- Query-expression based (for example `$expr`, logical operators)
- `$jsonSchema` based
- Combination of both (for example using `$and`)

```sql
SELECT documentdb_api.coll_mod(
	'documentdb',
	'students',
	'{
		"collMod": "students",
		"validator": {
			"$and": [
				{
					"$expr": {
						"$lt": ["$lineItems.discountedPrice", "$lineItems.price"]
					}
				},
				{
					"$jsonSchema": {
						"properties": {
							"items": { "bsonType": "array" }
						}
					}
				}
			]
		}
	}'
);
```

## Aggregation Write Stages (`$merge`, `$out`)

When a target collection has validation enabled:

- Documents produced by `$merge` / `$out` are validated before write.
- `validationAction` / `validationLevel` semantics are applied consistently with regular writes.
- Because writes execute through PostgreSQL statements, an error may roll back the statement atomically.

## Error Details

On validation failure, engine currently returns a validation failure error only. Detailed per-rule diagnostics (for example failing keyword, field path, and considered type/value) are not returned yet.

## Limitations and Future Work

The following items summarize the main open areas for schema validation and `$jsonSchema`:

1. **Missing `$jsonSchema` validators**
	- Not yet implemented: `maxProperties`, `minProperties`, `patternProperties`, `additionalProperties`, `dependencies`, `enum`, `allOf`, `anyOf`, `oneOf`, `not`, `title`.
2. **Validation error diagnostics depth**
	- Write-path error remains generic (no full per-rule hierarchical details yet).
3. **`validationAction: warn` behavior gap**
	- Current write path skips validation when action is `warn`; warning-style diagnostic logging behavior is not implemented.
4. **Schema-rule pre-validation coverage**
	- During `create` / `collMod`, syntax pre-validation focuses on `$jsonSchema` branches.
	- Non-`$jsonSchema` validator parts are not exhaustively pre-validated at DDL time and may fail later when the validator expression is compiled/evaluated on write paths.

## Related Docs

- JSON Schema behavior and compatibility: [json_schema.md](json_schema.md)
- Internal `$jsonSchema` model: [json_schema.md](json_schema.md#internal-implementation-summary)
