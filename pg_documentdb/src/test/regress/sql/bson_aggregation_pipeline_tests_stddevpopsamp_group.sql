SET search_path TO documentdb_api_catalog;

SET documentdb.next_collection_id TO 15100;
SET documentdb.next_collection_index_id TO 15100;

SELECT documentdb_api.insert_one('db','tests',' { "_id" : 1, "group": 1, "num" : 4 }');
SELECT documentdb_api.insert_one('db','tests',' { "_id" : 2, "group": 1, "num" : 7 }');
SELECT documentdb_api.insert_one('db','tests',' { "_id" : 3, "group": 1, "num" : 13 }');
SELECT documentdb_api.insert_one('db','tests',' { "_id" : 4, "group": 1, "num" : 16 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/* empty collection */
SELECT documentdb_api.insert_one('db','empty_col',' {"num": {} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "empty_col", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "empty_col", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*single number value in collection*/
SELECT documentdb_api.insert_one('db','single_num',' {"num": 1 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_num", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_num", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*two number values in collection*/
SELECT documentdb_api.insert_one('db','two_nums',' {"num": 1 }');
SELECT documentdb_api.insert_one('db','two_nums',' {"num": 1 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "two_nums", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "two_nums", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*single char value in collection*/
SELECT documentdb_api.insert_one('db','single_char',' {"num": "a" }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_char", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_char", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*single number and single char in collection*/
SELECT documentdb_api.insert_one('db','single_num_char',' {"num": 1 }');
SELECT documentdb_api.insert_one('db','single_num_char',' {"num": "a" }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_num_char", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_num_char", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*number and char mixed in collection*/
SELECT documentdb_api.insert_one('db','num_char_mixed',' {"num": 1 }');
SELECT documentdb_api.insert_one('db','num_char_mixed',' {"num": "a" }');
SELECT documentdb_api.insert_one('db','num_char_mixed',' {"num": 1 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_char_mixed", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_char_mixed", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*string in collection*/
SELECT documentdb_api.insert_one('db','num_string',' {"num": "string1" }');
SELECT documentdb_api.insert_one('db','num_string',' {"num": "string2" }');
SELECT documentdb_api.insert_one('db','num_string',' {"num": "strign3" }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_string", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_string", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*large number values in collection*/
SELECT documentdb_api.insert_one('db', 'large_num',' {"num": {"$numberLong": "10000000004"} }');
SELECT documentdb_api.insert_one('db', 'large_num',' {"num": {"$numberLong": "10000000007"} }');
SELECT documentdb_api.insert_one('db', 'large_num',' {"num": {"$numberLong": "10000000013"} }');
SELECT documentdb_api.insert_one('db', 'large_num',' {"num": {"$numberLong": "10000000016"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_num", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_num", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*double in collection*/
SELECT documentdb_api.insert_one('db', 'double',' {"num": {"$numberDouble": "4.0"} }');
SELECT documentdb_api.insert_one('db', 'double',' {"num": {"$numberDouble": "7.0"} }');
SELECT documentdb_api.insert_one('db', 'double',' {"num": {"$numberDouble": "13.0"} }');
SELECT documentdb_api.insert_one('db', 'double',' {"num": {"$numberDouble": "16.0"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "double", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "double", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*numberDecimal in collection*/
SELECT documentdb_api.insert_one('db', 'num_decimal',' {"num": {"$numberDecimal": "4"} }');
SELECT documentdb_api.insert_one('db', 'num_decimal',' {"num": {"$numberDecimal": "7"} }');
SELECT documentdb_api.insert_one('db', 'num_decimal',' {"num": {"$numberDecimal": "13"} }');
SELECT documentdb_api.insert_one('db', 'num_decimal',' {"num": {"$numberDecimal": "16"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_decimal", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_decimal", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*NaN and Infinity*/
SELECT documentdb_api.insert_one('db', 'single_nan',' {"num": {"$numberDecimal": "NaN" } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_nan", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_nan", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db', 'nans',' {"num": {"$numberDecimal": "NaN" } }');
SELECT documentdb_api.insert_one('db', 'nans',' {"num": {"$numberDecimal": "-NaN"} }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "nans", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "nans", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db','mix_nan',' {  "num" : 4 }');
SELECT documentdb_api.insert_one('db','mix_nan',' {  "num" : 7 }');
SELECT documentdb_api.insert_one('db','mix_nan',' {  "num" : 13 }');
SELECT documentdb_api.insert_one('db','mix_nan',' {  "num" : {"$numberDecimal": "NaN" } }');
SELECT documentdb_api.insert_one('db','mix_nan',' {  "num" : 16 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mix_nan", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mix_nan", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db', 'single_infinity',' {"num": {"$numberDecimal": "Infinity"} }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_infinity", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "single_infinity", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db', 'infinities',' {"num": { "$numberDecimal": "Infinity" } }');
SELECT documentdb_api.insert_one('db', 'infinities',' {"num": { "$numberDecimal": "-Infinity" } }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "infinities", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "infinities", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db','mix_inf',' {  "num" : 4 }');
SELECT documentdb_api.insert_one('db','mix_inf',' {  "num" : 7 }');
SELECT documentdb_api.insert_one('db','mix_inf',' {  "num" : 13 }');
SELECT documentdb_api.insert_one('db','mix_inf',' {  "num" : { "$numberDecimal": "Infinity" } }');
SELECT documentdb_api.insert_one('db','mix_inf',' {  "num" : 16 }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mix_inf", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "mix_inf", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/*number overflow*/
SELECT documentdb_api.insert_one('db','num_overflow',' {  "num" : {"$numberDecimal": "100000004"} }');
SELECT documentdb_api.insert_one('db','num_overflow',' {  "num" : {"$numberDecimal": "10000000007"} }');
SELECT documentdb_api.insert_one('db','num_overflow',' {  "num" : {"$numberDecimal": "1000000000000013"} }');
SELECT documentdb_api.insert_one('db','num_overflow',' {  "num" : {"$numberDecimal": "1000000000000000000"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_overflow", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_overflow", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/* int64 multiplication overflow in variance transition */
SELECT documentdb_api.insert_one('db','large_int64_near_max',' { "num" : {"$numberLong": "9223372036854775806"} }');
SELECT documentdb_api.insert_one('db','large_int64_near_max',' { "num" : {"$numberLong": "9223372036854775807"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_int64_near_max", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_int64_near_max", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

SELECT documentdb_api.insert_one('db','large_int64_spread',' { "num" : {"$numberLong": "0"} }');
SELECT documentdb_api.insert_one('db','large_int64_spread',' { "num" : {"$numberLong": "4611686018427387903"} }');
SELECT documentdb_api.insert_one('db','large_int64_spread',' { "num" : {"$numberLong": "9223372036854775807"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_int64_spread", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_int64_spread", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/* int64 multiplication overflow in moving-window inverse transition */
SELECT documentdb_api.insert_one('db','large_int64_window',' { "_id": 1, "x": {"$numberLong": "5000000000000000000"}, "y": {"$numberLong": "5000000000000000000"} }');
SELECT documentdb_api.insert_one('db','large_int64_window',' { "_id": 2, "x": {"$numberLong": "6000000000000000000"}, "y": {"$numberLong": "6000000000000000000"} }');
SELECT documentdb_api.insert_one('db','large_int64_window',' { "_id": 3, "x": {"$numberLong": "7000000000000000000"}, "y": {"$numberLong": "7000000000000000000"} }');
SELECT documentdb_api.insert_one('db','large_int64_window',' { "_id": 4, "x": {"$numberLong": "8000000000000000000"}, "y": {"$numberLong": "8000000000000000000"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "large_int64_window", "pipeline": [ { "$setWindowFields": { "sortBy": { "_id": 1 }, "output": { "stdDevPop": { "$stdDevPop": "$x", "window": { "documents": [-2, 0] } }, "stdDevSamp": { "$stdDevSamp": "$x", "window": { "documents": [-2, 0] } }, "covariancePop": { "$covariancePop": ["$x", "$y"], "window": { "documents": [-2, 0] } }, "covarianceSamp": { "$covarianceSamp": ["$x", "$y"], "window": { "documents": [-2, 0] } } } } }, { "$project": { "x": 0, "y": 0 } } ] }');

/* INT64_MIN subtraction while evicting a moving-window value */
SELECT documentdb_api_catalog.bson_expression_get(
	'{}',
	'{ "int64Exact": { "$subtract": [ { "$numberLong": "-9223372036854775808" }, { "$numberLong": "-9223372036854775808" } ] } }');
SELECT documentdb_api_catalog.bson_expression_get(
	'{}',
	'{ "int64Promoted": { "$subtract": [ 0, { "$numberLong": "-9223372036854775808" } ] } }');
SELECT documentdb_api_catalog.bson_expression_get(
	'{}',
	'{ "int32Exact": { "$subtract": [ { "$numberInt": "-2147483648" }, { "$numberInt": "-2147483648" } ] } }');

SELECT documentdb_api.insert_one('db','int64_min_window',' { "_id": 1, "x": {"$numberLong": "-9223372036854775808"}, "y": {"$numberLong": "-9223372036854775808"} }');
SELECT documentdb_api.insert_one('db','int64_min_window',' { "_id": 2, "x": {"$numberLong": "-9223372036854775808"}, "y": {"$numberLong": "-9223372036854775808"} }');
SELECT documentdb_api.insert_one('db','int64_min_window',' { "_id": 3, "x": {"$numberLong": "-9223372036854775808"}, "y": {"$numberLong": "-9223372036854775808"} }');
SELECT documentdb_api.insert_one('db','int64_min_window',' { "_id": 4, "x": {"$numberLong": "-9223372036854775808"}, "y": {"$numberLong": "-9223372036854775808"} }');

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "int64_min_window", "pipeline": [ { "$setWindowFields": { "sortBy": { "_id": 1 }, "output": { "stdDevPop": { "$stdDevPop": "$x", "window": { "documents": [-2, 0] } }, "stdDevSamp": { "$stdDevSamp": "$x", "window": { "documents": [-2, 0] } }, "covariancePop": { "$covariancePop": ["$x", "$y"], "window": { "documents": [-2, 0] } }, "covarianceSamp": { "$covarianceSamp": ["$x", "$y"], "window": { "documents": [-2, 0] } } } } }, { "$match": { "_id": 4 } }, { "$project": { "x": 0, "y": 0 } } ] }');

/* int64 multiplication overflow while combining partial aggregate states */
CREATE OR REPLACE FUNCTION documentdb_test_helpers.test_bson_statistics_combine_count_overflow()
RETURNS bool
LANGUAGE C
AS 'pg_documentdb', $$test_bson_statistics_combine_count_overflow$$;

SELECT documentdb_test_helpers.test_bson_statistics_combine_count_overflow();

DROP FUNCTION documentdb_test_helpers.test_bson_statistics_combine_count_overflow();

CREATE TABLE statistics_parallel_data (value documentdb_core.bson);
INSERT INTO statistics_parallel_data
	SELECT CASE WHEN i % 2 = 0
		THEN '{ "": { "$numberLong": "8000000000000000000" } }'
		ELSE '{ "": { "$numberLong": "5000000000000000000" } }'
		END::documentdb_core.bson
	FROM generate_series(1, 20000) i;
ANALYZE statistics_parallel_data;

SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
SET min_parallel_table_scan_size TO 0;
SET max_parallel_workers_per_gather TO 4;

EXPLAIN (COSTS OFF)
SELECT documentdb_api_internal.bsonstddevpop(value)
FROM statistics_parallel_data;

SELECT documentdb_core.bson_get_value_text(
	documentdb_api_internal.bsonstddevpop(value), '')::double precision
	BETWEEN 1.49e18 AND 1.51e18 AS combine_result_ok
FROM statistics_parallel_data;

RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers_per_gather;

DROP TABLE statistics_parallel_data;

/*array test*/
SELECT documentdb_api.insert_one('db','num_array',' {  "num" : [4, 7, 13, 16] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_array", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "num_array", "pipeline": [ { "$group": { "_id": 1, "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/* shard collection */
SELECT documentdb_api.shard_collection('db', 'tests', '{ "_id": "hashed" }', false);

SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevPop": "$num" } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevSamp": "$num" } } } ] }');

/* nagetive tests */
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevPop": ["$num"] } } } ] }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('db', '{ "aggregate": "tests", "pipeline": [ { "$group": { "_id": "$group", "stdDev": { "$stdDevSamp": ["$num"] } } } ] }');