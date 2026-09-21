SET search_path TO documentdb_api,documentdb_core;

SET documentdb.next_collection_id TO 101300;
SET documentdb.next_collection_index_id TO 101300;

--test int
select *from documentdb_api_catalog.bson_dollar_project('{"tests": 3}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": 3 } }');

--test double
select *from documentdb_api_catalog.bson_dollar_project('{"tests": 3.1}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": 3.1 } }');

--test string
select *from documentdb_api_catalog.bson_dollar_project('{"tests": "abc"}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": "abc" } }');

--test int64
select *from documentdb_api_catalog.bson_dollar_project('{"tests": 123456789012345678}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": 123456789012345678 } }');

--test array
select *from documentdb_api_catalog.bson_dollar_project('{"tests": [1, 2, 3.1]}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": [1, 2, 3.1] } }');

--test nested array
select *from documentdb_api_catalog.bson_dollar_project('{"tests": [1, 2, 3.1,[4, 5], 6]}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": [1, 2, 3.1,[4, 5], 6] } }');

--test nested object
select *from documentdb_api_catalog.bson_dollar_project('{"tests": [{"$numberDecimal": "1.2"},3]}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": [{"$numberDecimal": "1.2"},3] } }');

--test null
select *from documentdb_api_catalog.bson_dollar_project('{"tests": null}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": null } }');

--test NaN
select *from documentdb_api_catalog.bson_dollar_project('{"tests": {"$numberDouble": "NaN"}}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": {"$numberDouble": "NaN"} } }');

--test Infinity
select *from documentdb_api_catalog.bson_dollar_project('{"tests": {"$numberDouble": "Infinity"}}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": {"$numberDouble": "Infinity"} } }');

--test -Infinity
select *from documentdb_api_catalog.bson_dollar_project('{"tests": {"$numberDouble": "-Infinity"}}', '{"result": { "$toHashedIndexKey": "$tests" } }');
select *from documentdb_api_catalog.bson_dollar_project('{}', '{"result": { "$toHashedIndexKey": {"$numberDouble": "-Infinity"} } }');

--test path
select *from documentdb_api_catalog.bson_dollar_project('{"tests": {"test" : 5}}', '{"result": { "$toHashedIndexKey": "$tests.test" } }');
select *from documentdb_api_catalog.bson_dollar_project('{"tests": 3}', '{"result": { "$toHashedIndexKey": "$test" } }');
select *from documentdb_api_catalog.bson_dollar_project('{"tests": {"test" : 5}}', '{"result": { "$toHashedIndexKey": "$tests.tes" } }');

SELECT name, documentdb_api_catalog.bson_dollar_project(document::bson, expression::bson) = expected::bson AS matches
FROM (VALUES
	('runtime_ascii', '{"s":" ABC "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QUJD","subType":"00"}}}'),
	('runtime_multibyte', '{"s":" \u00e9 "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"w6k=","subType":"00"}}}'),
	('stored_utf8', '{"s":"A\u0000B"}', '{"result":{"$convert":{"input":"$s","to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QQBC","subType":"00"}}}'),
	('hex_null', '{"s":"41\u000042"}', '{"result":{"$convert":{"input":"$s","to":"binData","format":"hex","onError":null}}}', '{"result":null}'),
	('base64url_null', '{"s":"QUI\u0000"}', '{"result":{"$convert":{"input":"$s","to":"binData","format":"base64url","onError":null}}}', '{"result":null}'),
	('literal_utf8', '{}', '{"result":{"$convert":{"input":{"$trim":{"input":" A\u0000B "}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QQBC","subType":"00"}}}'),
	('runtime_utf8', '{"s":" A\u0000B "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QQBC","subType":"00"}}}'),
	('runtime_ltrim', '{"s":" A\u0000B"}', '{"result":{"$convert":{"input":{"$ltrim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QQBC","subType":"00"}}}'),
	('runtime_rtrim', '{"s":"A\u0000B "}', '{"result":{"$convert":{"input":{"$rtrim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"QQBC","subType":"00"}}}'),
	('runtime_empty', '{"s":"   "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"utf8"}}}', '{"result":{"$binary":{"base64":"","subType":"00"}}}'),
	('runtime_base64', '{"s":" QUI= "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"base64"}}}', '{"result":{"$binary":{"base64":"QUI=","subType":"00"}}}'),
	('runtime_base64url', '{"s":" -_8 "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"base64url"}}}', '{"result":{"$binary":{"base64":"+/8=","subType":"00"}}}'),
	('runtime_hex', '{"s":" 4142 "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":"binData","format":"hex"}}}', '{"result":{"$binary":{"base64":"QUI=","subType":"00"}}}'),
	('runtime_uuid', '{"s":" 00112233-4455-6677-8899-aabbccddeeff "}', '{"result":{"$convert":{"input":{"$trim":{"input":"$s"}},"to":{"type":"binData","subtype":4},"format":"uuid"}}}', '{"result":{"$binary":{"base64":"ABEiM0RVZneImaq7zN3u/w==","subType":"04"}}}')
) AS cases(name, document, expression, expected)
ORDER BY name;