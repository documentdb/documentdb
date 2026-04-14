SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core,pg_catalog;

SET documentdb.next_collection_id TO 25702000;
SET documentdb.next_collection_index_id TO 25702000;

-- =============================================================================
-- Test 1: $group + $sum/$avg on integer fields
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 1, "category": "A", "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 2, "category": "A", "value": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 3, "category": "A", "value": 30 }');
SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 4, "category": "B", "value": 5 }');
SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 5, "category": "B", "value": 15 }');
SELECT documentdb_api.insert_one('db','sumavg_int_test','{ "_id": 6, "category": "B", "value": 25 }');

-- $sum on integer field
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" } } }, { "$sort": { "_id": 1 } } ] }');

-- $avg on integer field
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');

-- $sum and $avg together
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');

-- $sum with constant value (count pattern)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ] }');

-- $sum with constant value > 1
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "weighted": { "$sum": 5 } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "weighted": { "$sum": 5 } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 2: $group + $sum/$avg on double fields
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_double_test','{ "_id": 1, "category": "X", "value": 1.5 }');
SELECT documentdb_api.insert_one('db','sumavg_double_test','{ "_id": 2, "category": "X", "value": 2.5 }');
SELECT documentdb_api.insert_one('db','sumavg_double_test','{ "_id": 3, "category": "X", "value": 3.5 }');
SELECT documentdb_api.insert_one('db','sumavg_double_test','{ "_id": 4, "category": "Y", "value": 0.1 }');
SELECT documentdb_api.insert_one('db','sumavg_double_test','{ "_id": 5, "category": "Y", "value": 0.2 }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_double_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_double_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 3: $group + $sum/$avg on mixed numeric types
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_mixed_test','{ "_id": 1, "category": "M", "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_mixed_test','{ "_id": 2, "category": "M", "value": 2.5 }');
SELECT documentdb_api.insert_one('db','sumavg_mixed_test','{ "_id": 3, "category": "M", "value": {"$numberLong": "100"} }');
SELECT documentdb_api.insert_one('db','sumavg_mixed_test','{ "_id": 4, "category": "M", "value": {"$numberDecimal": "7.25"} }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_mixed_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_mixed_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');

-- =============================================================================
-- Test 4: $sum/$avg with non-numeric values (should be ignored)
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_nonnumeric_test','{ "_id": 1, "category": "A", "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_nonnumeric_test','{ "_id": 2, "category": "A", "value": "hello" }');
SELECT documentdb_api.insert_one('db','sumavg_nonnumeric_test','{ "_id": 3, "category": "A", "value": true }');
SELECT documentdb_api.insert_one('db','sumavg_nonnumeric_test','{ "_id": 4, "category": "A", "value": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_nonnumeric_test','{ "_id": 5, "category": "A", "value": [1, 2, 3] }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_nonnumeric_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_nonnumeric_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');

-- =============================================================================
-- Test 5: $sum/$avg with null and missing fields
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_null_test','{ "_id": 1, "category": "A", "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_null_test','{ "_id": 2, "category": "A", "value": null }');
SELECT documentdb_api.insert_one('db','sumavg_null_test','{ "_id": 3, "category": "A" }');
SELECT documentdb_api.insert_one('db','sumavg_null_test','{ "_id": 4, "category": "A", "value": 20 }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_null_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_null_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');

-- =============================================================================
-- Test 6: $sum/$avg on empty group (no documents matching)
-- =============================================================================

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_null_test", "pipeline": [ { "$match": { "_id": 999 } }, { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_null_test", "pipeline": [ { "$match": { "_id": 999 } }, { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');

-- =============================================================================
-- Test 7: $sum/$avg with _id: null (single group)
-- =============================================================================

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$value" }, "average": { "$avg": "$value" }, "count": { "$sum": 1 } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$value" }, "average": { "$avg": "$value" }, "count": { "$sum": 1 } } } ] }');

-- =============================================================================
-- Test 8: $sum/$avg with expressions
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_expr_test','{ "_id": 1, "price": 10, "qty": 2 }');
SELECT documentdb_api.insert_one('db','sumavg_expr_test','{ "_id": 2, "price": 20, "qty": 3 }');
SELECT documentdb_api.insert_one('db','sumavg_expr_test','{ "_id": 3, "price": 30, "qty": 1 }');

-- $sum with $multiply expression
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr_test", "pipeline": [ { "$group": { "_id": null, "totalRevenue": { "$sum": { "$multiply": ["$price", "$qty"] } }, "avgRevenue": { "$avg": { "$multiply": ["$price", "$qty"] } } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr_test", "pipeline": [ { "$group": { "_id": null, "totalRevenue": { "$sum": { "$multiply": ["$price", "$qty"] } }, "avgRevenue": { "$avg": { "$multiply": ["$price", "$qty"] } } } } ] }');

-- $sum/$avg with nested field paths
SELECT documentdb_api.insert_one('db','sumavg_nested_test','{ "_id": 1, "info": { "score": 85 } }');
SELECT documentdb_api.insert_one('db','sumavg_nested_test','{ "_id": 2, "info": { "score": 92 } }');
SELECT documentdb_api.insert_one('db','sumavg_nested_test','{ "_id": 3, "info": { "score": 78 } }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_nested_test", "pipeline": [ { "$group": { "_id": null, "totalScore": { "$sum": "$info.score" }, "avgScore": { "$avg": "$info.score" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_nested_test", "pipeline": [ { "$group": { "_id": null, "totalScore": { "$sum": "$info.score" }, "avgScore": { "$avg": "$info.score" } } } ] }');

-- =============================================================================
-- Test 9: $sum/$avg with $let variables
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_let_test','{ "_id": 1, "price": 10, "tax": 0.1 }');
SELECT documentdb_api.insert_one('db','sumavg_let_test','{ "_id": 2, "price": 20, "tax": 0.15 }');
SELECT documentdb_api.insert_one('db','sumavg_let_test','{ "_id": 3, "price": 30, "tax": 0.2 }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_let_test", "pipeline": [ { "$group": { "_id": null, "totalWithTax": { "$sum": { "$let": { "vars": { "total": { "$multiply": ["$price", { "$add": [1, "$tax"] }] } }, "in": "$$total" } } } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_let_test", "pipeline": [ { "$group": { "_id": null, "totalWithTax": { "$sum": { "$let": { "vars": { "total": { "$multiply": ["$price", { "$add": [1, "$tax"] }] } }, "in": "$$total" } } } } } ] }');

-- =============================================================================
-- Test 10: $setWindowFields with $sum and $avg - document window
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 1, "partition": "A", "order": 1, "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 2, "partition": "A", "order": 2, "value": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 3, "partition": "A", "order": 3, "value": 30 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 4, "partition": "A", "order": 4, "value": 40 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 5, "partition": "B", "order": 1, "value": 5 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 6, "partition": "B", "order": 2, "value": 15 }');
SELECT documentdb_api.insert_one('db','sumavg_window_test','{ "_id": 7, "partition": "B", "order": 3, "value": 25 }');

-- unbounded $sum window
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- unbounded $avg window
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 11: $setWindowFields with moving window (validates inverse transition)
-- =============================================================================

-- sliding window of size 2 with $sum
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "slidingSum": { "$sum": "$value", "window": { "documents": [-1, 0] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "slidingSum": { "$sum": "$value", "window": { "documents": [-1, 0] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- sliding window of size 3 with $avg
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "slidingAvg": { "$avg": "$value", "window": { "documents": [-1, 1] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "slidingAvg": { "$avg": "$value", "window": { "documents": [-1, 1] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 12: $setWindowFields with $sum using no explicit window (whole partition)
-- =============================================================================

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "partitionSum": { "$sum": "$value" }, "partitionAvg": { "$avg": "$value" } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": {"order": 1}, "output": { "partitionSum": { "$sum": "$value" }, "partitionAvg": { "$avg": "$value" } } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 13: $setWindowFields with $sum/$avg on window with null/missing values
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 1, "order": 1, "value": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 2, "order": 2, "value": null }');
SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 3, "order": 3 }');
SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 4, "order": 4, "value": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 5, "order": 5, "value": "text" }');
SELECT documentdb_api.insert_one('db','sumavg_window_null_test','{ "_id": 6, "order": 6, "value": 30 }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_null_test", "pipeline": [ { "$setWindowFields": { "sortBy": {"order": 1}, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } }, "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_null_test", "pipeline": [ { "$setWindowFields": { "sortBy": {"order": 1}, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } }, "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- moving window with null/missing (exercises inverse transition with non-numeric skipping)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_null_test", "pipeline": [ { "$setWindowFields": { "sortBy": {"order": 1}, "output": { "slidingSum": { "$sum": "$value", "window": { "documents": [-1, 1] } }, "slidingAvg": { "$avg": "$value", "window": { "documents": [-1, 1] } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_null_test", "pipeline": [ { "$setWindowFields": { "sortBy": {"order": 1}, "output": { "slidingSum": { "$sum": "$value", "window": { "documents": [-1, 1] } }, "slidingAvg": { "$avg": "$value", "window": { "documents": [-1, 1] } } } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 14: $sum with $group + $sum: {} (empty document sum)
-- =============================================================================

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": null, "result": { "$sum": {} } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": null, "result": { "$sum": {} } } } ] }');

-- =============================================================================
-- Test 15: $sum/$avg with $group on all same values
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_same_test','{ "_id": 1, "value": 7 }');
SELECT documentdb_api.insert_one('db','sumavg_same_test','{ "_id": 2, "value": 7 }');
SELECT documentdb_api.insert_one('db','sumavg_same_test','{ "_id": 3, "value": 7 }');

SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_same_test", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_same_test", "pipeline": [ { "$group": { "_id": null, "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } } ] }');

-- =============================================================================
-- Test 16: Extreme Int64 and Decimal128 values
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 1, "group": "int64", "val": { "$numberLong": "9223372036854775807" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 2, "group": "int64", "val": { "$numberLong": "-9223372036854775808" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 3, "group": "int64", "val": { "$numberLong": "0" } }');

SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 4, "group": "decimal", "val": { "$numberDecimal": "9.999999999999999999999999999999999E6144" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 5, "group": "decimal", "val": { "$numberDecimal": "-9.999999999999999999999999999999999E6144" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 6, "group": "decimal", "val": { "$numberDecimal": "0" } }');

SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 7, "group": "special", "val": { "$numberDecimal": "Infinity" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 8, "group": "special", "val": { "$numberDecimal": "-Infinity" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 9, "group": "special", "val": { "$numberDecimal": "NaN" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 10, "group": "special", "val": 100 }');

SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 11, "group": "mixednums", "val": { "$numberLong": "9223372036854775807" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 12, "group": "mixednums", "val": { "$numberDouble": "1.7976931348623157e308" } }');
SELECT documentdb_api.insert_one('db','sumavg_extreme_test','{ "_id": 13, "group": "mixednums", "val": { "$numberDecimal": "1E6144" } }');

-- Int64 extremes
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "int64" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "int64" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');

-- Decimal128 extremes
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "decimal" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "decimal" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');

-- Special values (Infinity, -Infinity, NaN)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "special" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "special" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');

-- Mixed numeric types
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "mixednums" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$match": { "group": "mixednums" } }, { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } } ] }');

-- All groups
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_extreme_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$val" }, "average": { "$avg": "$val" } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 17: Using $$variable in $sum/$avg expression
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_variable_test','{ "_id": 1, "group": "A", "val": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_variable_test','{ "_id": 2, "group": "A", "val": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_variable_test','{ "_id": 3, "group": "A", "val": 15 }');
SELECT documentdb_api.insert_one('db','sumavg_variable_test','{ "_id": 4, "group": "B", "val": 5 }');
SELECT documentdb_api.insert_one('db','sumavg_variable_test','{ "_id": 5, "group": "B", "val": 25 }');

-- Using $$variable with $add
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "sumWithOffset": { "$sum": { "$add": ["$val", "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 100 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "sumWithOffset": { "$sum": { "$add": ["$val", "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 100 } }');

-- Using $$variable with $avg
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "avgWithOffset": { "$avg": { "$add": ["$val", "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 50 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "avgWithOffset": { "$avg": { "$add": ["$val", "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 50 } }');

-- Multiple variables
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "sumCalc": { "$sum": { "$add": [{ "$multiply": ["$val", "$$multiplier"] }, "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 10, "multiplier": 2 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "sumCalc": { "$sum": { "$add": [{ "$multiply": ["$val", "$$multiplier"] }, "$$offset"] } } } }, { "$sort": { "_id": 1 } } ], "let": { "offset": 10, "multiplier": 2 } }');

-- Using $$CURRENT
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$$CURRENT.val" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$$CURRENT.val" } } }, { "$sort": { "_id": 1 } } ] }');

-- Using $$ROOT
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$$ROOT.val" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_variable_test", "pipeline": [ { "$group": { "_id": "$group", "total": { "$sum": "$$ROOT.val" } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 18: Expression evaluation within accumulator ($add, $subtract, nested)
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_expr2_test','{ "_id": 1, "group": "A", "a": 10, "b": 5 }');
SELECT documentdb_api.insert_one('db','sumavg_expr2_test','{ "_id": 2, "group": "A", "a": 3, "b": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_expr2_test','{ "_id": 3, "group": "A", "a": 8, "b": 8 }');
SELECT documentdb_api.insert_one('db','sumavg_expr2_test','{ "_id": 4, "group": "B", "a": 100, "b": 1 }');
SELECT documentdb_api.insert_one('db','sumavg_expr2_test','{ "_id": 5, "group": "B", "a": 50, "b": 50 }');

-- $add expression
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumAdd": { "$sum": { "$add": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumAdd": { "$sum": { "$add": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "avgAdd": { "$avg": { "$add": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "avgAdd": { "$avg": { "$add": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');

-- $subtract expression
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumDiff": { "$sum": { "$subtract": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumDiff": { "$sum": { "$subtract": ["$a", "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');

-- Nested expression: multiply then add
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumCalc": { "$sum": { "$add": [{ "$multiply": ["$a", 2] }, "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "sumCalc": { "$sum": { "$add": [{ "$multiply": ["$a", 2] }, "$b"] } } } }, { "$sort": { "_id": 1 } } ] }');

-- Complex nested expression
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "avgComplex": { "$avg": { "$multiply": [{ "$add": ["$a", "$b"] }, 2] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_expr2_test", "pipeline": [ { "$group": { "_id": "$group", "avgComplex": { "$avg": { "$multiply": [{ "$add": ["$a", "$b"] }, 2] } } } }, { "$sort": { "_id": 1 } } ] }');

-- =============================================================================
-- Test 19: Conditional logic in accumulator input ($cond, $ifNull)
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 1, "group": "A", "val": 10, "active": true }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 2, "group": "A", "val": 50, "active": false }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 3, "group": "A", "val": 30, "active": true }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 4, "group": "B", "val": 100, "active": true }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 5, "group": "B", "val": 200, "active": false }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 6, "group": "B", "val": 75, "active": true }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 7, "group": "C", "val": 25, "optionalField": 999 }');
SELECT documentdb_api.insert_one('db','sumavg_cond_test','{ "_id": 8, "group": "C", "val": 50 }');

-- $cond: if active then val else 0
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "sumActive": { "$sum": { "$cond": { "if": "$active", "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "sumActive": { "$sum": { "$cond": { "if": "$active", "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $cond: if active then val else null (null values ignored by $avg)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "avgActive": { "$avg": { "$cond": { "if": "$active", "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "avgActive": { "$avg": { "$cond": { "if": "$active", "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $cond with array syntax
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "tier": { "$sum": { "$cond": [{ "$gt": ["$val", 50] }, { "$multiply": ["$val", 2] }, "$val"] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "tier": { "$sum": { "$cond": [{ "$gt": ["$val", 50] }, { "$multiply": ["$val", 2] }, "$val"] } } } }, { "$sort": { "_id": 1 } } ] }');

-- $ifNull expression
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "sumWithDefault": { "$sum": { "$ifNull": ["$optionalField", 0] } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "sumWithDefault": { "$sum": { "$ifNull": ["$optionalField", 0] } } } }, { "$sort": { "_id": 1 } } ] }');

-- Nested $cond
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "categorized": { "$sum": { "$cond": { "if": { "$gt": ["$val", 100] }, "then": 3, "else": { "$cond": { "if": { "$gt": ["$val", 50] }, "then": 2, "else": 1 } } } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_cond_test", "pipeline": [ { "$group": { "_id": "$group", "categorized": { "$sum": { "$cond": { "if": { "$gt": ["$val", 100] }, "then": 3, "else": { "$cond": { "if": { "$gt": ["$val", 50] }, "then": 2, "else": 1 } } } } } } }, { "$sort": { "_id": 1 } } ] }');


-- =============================================================================
-- Test 20: EXPLAIN query plan verification
-- =============================================================================

-- EXPLAIN to verify query plan for $group
SET documentdb.enableNewWithExprAccumulators TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_int_test", "pipeline": [ { "$group": { "_id": "$category", "total": { "$sum": "$value" }, "average": { "$avg": "$value" } } }, { "$sort": { "_id": 1 } } ] }');

-- EXPLAIN to verify query plan for $setWindowFields
SET documentdb.enableNewWithExprAccumulators TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": { "order": 1 }, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } }, "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_window_test", "pipeline": [ { "$setWindowFields": { "partitionBy": "$partition", "sortBy": { "order": 1 }, "output": { "runningSum": { "$sum": "$value", "window": { "documents": ["unbounded", "current"] } }, "runningAvg": { "$avg": "$value", "window": { "documents": ["unbounded", "current"] } } } } } ] }');

-- =============================================================================
-- Test 21: $sum/$avg with collation-sensitive $cond expression
-- Collation affects expression evaluation inside the accumulator input.
-- With the WithExpr path (enableNewWithExprAccumulators=on), collation is
-- propagated to bsonsumwithexpr/bsonaveragewithexpr, so $eq comparisons
-- respect collation (e.g., "cherry" == "CHERRY" with strength 1).
-- The legacy path (enableNewWithExprAccumulators=off) errors with
-- "collation is not supported in $group stage yet."
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_collation_test','{ "_id": 1, "group": "A", "name": "cherry", "val": 10 }');
SELECT documentdb_api.insert_one('db','sumavg_collation_test','{ "_id": 2, "group": "A", "name": "BANANA", "val": 20 }');
SELECT documentdb_api.insert_one('db','sumavg_collation_test','{ "_id": 3, "group": "A", "name": "Apple", "val": 30 }');
SELECT documentdb_api.insert_one('db','sumavg_collation_test','{ "_id": 4, "group": "a", "name": "date", "val": 40 }');
SELECT documentdb_api.insert_one('db','sumavg_collation_test','{ "_id": 5, "group": "a", "name": "FIG", "val": 50 }');

SET documentdb_core.enableCollation TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

-- $sum counting matches: count docs where name case-insensitively equals "CHERRY"
-- Legacy path errors; WithExpr path correctly applies collation (matchCount = 1 for group "A").
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline (binary: "cherry" != "CHERRY", no matches)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $sum conditional value: sum val for matching docs, 0 otherwise
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedSum": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedSum": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedSum": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedSum": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $avg with conditional filter: average val for matching docs, null otherwise
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $sum and $avg together with collation strength 2 (case-insensitive, accent-sensitive)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } }, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 2 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } }, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 2 } }');

-- =============================================================================
-- Test 22: EXPLAIN showing collation propagation in WithExpr aggregate functions
-- =============================================================================

-- With collation: collation text constant should appear in bsonsumwithexpr/bsonaveragewithexpr args
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation: NULL collation arg
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');

-- EXPLAIN for $avg with collation
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- =============================================================================
-- Test 23: Constant _id group with collation-sensitive expression
-- =============================================================================

-- $sum counting with _id: null (all docs in one group)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline on constant group
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } } ] }');

-- $avg with constant _id: null
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": null, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } } ], "collation": { "locale": "en", "strength": 1 } }');

-- With constant _id: 1
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": 1, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } }, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": 1, "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } }, "matchedAvg": { "$avg": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "$val", "else": null } } } } } ], "collation": { "locale": "en", "strength": 1 } }');

-- =============================================================================
-- Test 24: Collation with $sum/$avg on mixed types
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_collation_mixed','{ "_id": 1, "group": "G", "val": "banana" }');
SELECT documentdb_api.insert_one('db','sumavg_collation_mixed','{ "_id": 2, "group": "G", "val": "CHERRY" }');
SELECT documentdb_api.insert_one('db','sumavg_collation_mixed','{ "_id": 3, "group": "G", "val": 42 }');
SELECT documentdb_api.insert_one('db','sumavg_collation_mixed','{ "_id": 4, "group": "G", "val": null }');

-- With collation: "CHERRY" case-insensitively equals "cherry" → count 1; number/null don't match
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_mixed", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": 1, "else": 0 } } } } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_mixed", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": 1, "else": 0 } } } } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline (binary: "CHERRY" != "cherry")
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_mixed", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": 1, "else": 0 } } } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_mixed", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": 1, "else": 0 } } } } } ] }');

-- =============================================================================
-- Test 25: Collation with numericOrdering on $sum/$avg
-- With numericOrdering: "item10" > "item2" (numeric), without: "item10" < "item2" (lexical)
-- =============================================================================

SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 1, "cat": "A", "val": "item1" }');
SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 2, "cat": "A", "val": "item10" }');
SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 3, "cat": "A", "val": "item2" }');
SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 4, "cat": "B", "val": "item20" }');
SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 5, "cat": "B", "val": "item3" }');
SELECT documentdb_api.insert_one('db','sumavg_numeric_order','{ "_id": 6, "cat": "B", "val": "item5" }');

-- $sum counting items greater than "item2"
-- numericOrdering=true: "item10">true, "item1">false, "item2">false for A; "item20">true, "item3">true, "item5">true for B
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": true } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": true } }');

-- numericOrdering=false (lexical): "item10"<"item2", "item20">"item2", "item3">"item2", "item5">"item2"
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": false } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": false } }');

-- Without collation baseline (same as numericOrdering=false)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "countAbove": { "$sum": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ] }');

-- $avg scoring: average 10 for items above threshold, 0 otherwise
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "avgScore": { "$avg": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 10, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": true } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_numeric_order", "pipeline": [ { "$group": { "_id": "$cat", "avgScore": { "$avg": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": 10, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "numericOrdering": true } }');

-- =============================================================================
-- Test 26: Collation blocked when enableCollationWithNewGroupAccumulators is off
-- =============================================================================

SET documentdb.enableNewWithExprAccumulators TO off;
SET documentdb.enableCollationWithNewGroupAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

-- =============================================================================
-- Test 27: enableCollation off → collation ignored, binary comparison applies
-- =============================================================================

SET documentdb_core.enableCollation TO off;
-- With enableCollation off, collation is simply ignored and binary comparison applies.
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sumavg_collation_test", "pipeline": [ { "$group": { "_id": "$group", "matchCount": { "$sum": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": 1, "else": 0 } } } } }, { "$sort": { "_id": 1 } } ], "collation": { "locale": "en", "strength": 1 } }');

-- Cleanup GUC settings
SET documentdb.enableCollationWithNewGroupAccumulators TO off;
SET documentdb_core.enableCollation TO off;
RESET documentdb.enableNewWithExprAccumulators;

-- =============================================================================
-- Test 28: enableSortGroupStage drops dead outer $sort for order-insensitive
--          $group accumulators while preserving results
-- =============================================================================

SELECT documentdb_api.insert_one('db','sortgroup_safe_test','{ "_id": 1, "g": "A", "seq": 30, "v": 10, "bonus": 2 }');
SELECT documentdb_api.insert_one('db','sortgroup_safe_test','{ "_id": 2, "g": "A", "seq": 10, "v": 6, "bonus": 4 }');
SELECT documentdb_api.insert_one('db','sortgroup_safe_test','{ "_id": 3, "g": "B", "seq": 20, "v": 5, "bonus": 1 }');
SELECT documentdb_api.insert_one('db','sortgroup_safe_test','{ "_id": 4, "g": "B", "seq": 40, "v": 9, "bonus": 3 }');

-- With sortGroup disabled, the user $sort on seq should remain in the plan.
SET documentdb.enableSortGroupStage TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "adjustedAverage": { "$avg": { "$add": ["$v", "$bonus"] } }, "lo": { "$min": "$v" }, "hi": { "$max": "$v" }, "count": { "$count": {} } } }, { "$sort": { "_id": 1 } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "adjustedAverage": { "$avg": { "$add": ["$v", "$bonus"] } }, "lo": { "$min": "$v" }, "hi": { "$max": "$v" }, "count": { "$count": {} } } }, { "$sort": { "_id": 1 } } ] }');

-- With sortGroup enabled, the dead outer $sort on seq should disappear, but
-- the grouped results should stay identical.
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "adjustedAverage": { "$avg": { "$add": ["$v", "$bonus"] } }, "lo": { "$min": "$v" }, "hi": { "$max": "$v" }, "count": { "$count": {} } } }, { "$sort": { "_id": 1 } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "adjustedAverage": { "$avg": { "$add": ["$v", "$bonus"] } }, "lo": { "$min": "$v" }, "hi": { "$max": "$v" }, "count": { "$count": {} } } }, { "$sort": { "_id": 1 } } ] }');

-- Test 29: Invalid sort direction with order-insensitive accumulators
-- Even when the sort could be dropped, an invalid sort spec should still error.
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "myFoobar": "InvalidDirection" } }, { "$group": { "_id": null, "c": { "$max": "$v" } } } ] }');

-- Test 30: Non-$ prefixed path in accumulator should fail in group validation
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": null, "c": { "notAnOperator": "$v" } } } ] }');

-- Test 31: $push is order-sensitive — sort must be preserved
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "vals": { "$push": "$v" } } }, { "$sort": { "_id": 1 } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "vals": { "$push": "$v" } } }, { "$sort": { "_id": 1 } } ] }');

-- Test 32: $stdDevPop is order-insensitive but not in the allowlist — sort must be preserved
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "sd": { "$stdDevPop": "$v" } } }, { "$sort": { "_id": 1 } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "sd": { "$stdDevPop": "$v" } } }, { "$sort": { "_id": 1 } } ] }');

-- Test 33: Mixed accumulators ($sum + $first) — sort must be preserved
-- When order-insensitive and order-sensitive accumulators appear in the same
-- $group, the sort cannot be dropped because $first depends on encounter order.
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "firstVal": { "$first": "$v" } } }, { "$sort": { "_id": 1 } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "sortgroup_safe_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "total": { "$sum": "$v" }, "firstVal": { "$first": "$v" } } }, { "$sort": { "_id": 1 } } ] }');

RESET documentdb.enableSortGroupStage;
SELECT documentdb_api.drop_collection('db', 'sortgroup_safe_test');
