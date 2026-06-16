SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 220000;
SET documentdb.next_collection_id TO 2200;
SET documentdb.next_collection_index_id TO 2200;

-- arrayFilters with aggregation pipeline
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": [ { "$addFields": { "fieldA.fieldB": 10 } }]}', '{}', NULL::documentdb_core.bson, NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": [ { "$addFields": { "fieldA.fieldB": 10 } }]}', '{}', NULL::documentdb_core.bson, NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": [ { "$addFields": { "fieldA.fieldB": 10 } }]}', '{}', '{ "": [ { "filterX": 30 }]}', NULL::documentdb_core.bson, NULL::TEXT);

-- arrayFilters ignored on replace
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "fieldC": 40 } }', '{}', '{ "": [ { "filterX": 50 }]}', NULL::documentdb_core.bson, NULL::TEXT);

-- arrayFilters with update fails - missing array filter
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 60 }}}', '{}', '{ "": [] }', NULL::documentdb_core.bson, NULL::TEXT);

-- arrayFilters with update fails - invalid array filters
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 70 }}}', '{}', '{ "": [ 2 ] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 70 }}}', '{}', '{ "": [ {} ] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 70 }}}', '{}', '{ "": [ { "": 3} ] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 70 }}}', '{}', '{ "": [ { "itemA": 4, "itemB.itemC": 5 } ] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "arrayA.$[itemA]": 70 }}}', '{}', '{ "": [ { "itemA": 6 }, { "itemA": 7 } ] }', NULL::documentdb_core.bson, NULL::TEXT);

-- simple array update on equality
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1, "numbers": [ 100, 200 ] }','{ "": { "$set": { "numbers.$[numElem]": 300 }}}', '{}', '{ "": [{ "numElem": 100 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{}','{ "": { "$set": { "numbers.$[numElem]": 300 }}}', '{"_id": 1, "numbers": [ 100, 200 ] }', '{ "": [{ "numElem": 100 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1 }','{ "": { "$set": { "numbers.$[numElem]": 300 }}}', '{}', '{ "": [{ "numElem": 100 }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- updates on $gte condition
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "scores" : [ 150, 120, 110 ], "age": 15 }','{ "": { "$set": { "scores.$[scoreElem]": 200 }}}', '{}', '{ "": [{ "scoreElem": { "$gte": 200 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "scores" : [ 150, 210, 200, 180, 202 ], "age": 16 }','{ "": { "$set": { "scores.$[scoreElem]": 200 }}}', '{}', '{ "": [{ "scoreElem": { "$gte": 200 } }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- nested arrayFilters.
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "metrics" : [ { "value": 58, "max": 136, "avg": 66, "dev": 88}, { "value": 96, "max": 176, "avg": 99, "dev": 75}, { "value": 68, "max":168, "avg": 86, "dev": 83 } ] }',
    '{ "": { "$set": { "metrics.$[metricElem].avg": 100 }}}', '{}', '{ "": [{ "metricElem.value": { "$gte": 60 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "metrics" : [ { "value": 58, "max": 136, "avg": 66, "dev": 88}, { "value": 96, "max": 176, "avg": 99, "dev": 75 }, { "value": 68, "max":168, "avg": 86, "dev": 83 } ] }',
    '{ "": { "$inc": { "metrics.$[metricElem].dev": -50 }}}', '{}', '{ "": [{ "metricElem.value": { "$gte": 60 }, "metricElem.dev": { "$gte": 80 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "metrics" : [ { "value": 58, "max": 136, "avg": 66, "dev": 88}, { "value": 96, "max": 176, "avg": 99, "dev": 75 }, { "value": 68, "max":168, "avg": 86, "dev": 83 } ] }',
    '{ "": { "$inc": { "metrics.$[metricElem].dev": -50 }}}', '{}', '{ "": [{ "metricElem.value": { "$gte": 60 }, "metricElem.dev": { "$gte": 75 } }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- negation operators
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "degreesList" : [ { "level": "PhD", "age": 28}, { "level": "Bachelor", "age": 22} ] }',
    '{ "": { "$set" : { "degreesList.$[deg].gradYear" : 2020 }} }', '{}', '{ "": [{ "deg.level": { "$ne": "Bachelor" } }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- multiple positional operators
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "results" : [ { "type": "quiz", "answers": [ 20, 18, 15 ] }, { "type": "quiz", "answers": [ 18, 19, 16 ] }, { "type": "hw", "answers": [ 15, 14, 13 ] }, { "type": "exam", "answers": [ 35, 20, 33, 10 ] }] }',
    '{ "": { "$inc": { "results.$[typeElem].answers.$[ansScore]": 190 }} }', '{}', '{ "": [{ "typeElem.type": "quiz" }, { "ansScore": { "$gte": 18 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "results" : [ { "type": "quiz", "answers": [ 20, 18, 15 ] }, { "type": "quiz", "answers": [ 18, 19, 16 ] }, { "type": "hw", "answers": [ 15, 14, 13 ] }, { "type": "exam", "answers": [ 35, 20, 33, 10 ] }] }',
    '{ "": { "$inc": { "results.$[].answers.$[ansScore]": 190 }} }', '{}', '{ "": [{ "ansScore": { "$gte": 18 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "results" : [ { "type": "quiz", "answers": [ 20, 18, 15 ] }, { "type": "quiz", "answers": [ 18, 19, 16 ] }, { "type": "hw", "answers": [ 15, 14, 13 ] }, { "type": "exam", "answers": [ 35, 20, 33, 10 ] }] }',
        '{ "": { "$inc": { "results.$[typeElem].answers.$[]": 190 }} }', '{}',  '{ "": [{ "typeElem.type": "quiz" }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- arrayFilters for all Update operators should recurse if for a single level nested array
-- array update operators
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$addToSet": { "matrix.$[row]": 2 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0, 1], [1, 2] ] }',
    '{ "": { "$pop": { "matrix.$[row]": 1 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0, 1], [1, 2] ] }',
    '{ "": { "$pull": { "matrix.$[row]": 1 }} }', '{}', '{ "": [{ "row": 2 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0, 1], [1, 2] ] }',
    '{ "": { "$pull": { "matrix.$[row]": 1 }} }', '{}', '{ "": [{ "row": 2 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0, 1], [2, 3] ] }',
    '{ "": { "$push": { "matrix.$[row]": 1 }} }', '{}', '{ "": [{ "row": 1 }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- field update operators, should be able to match but apply update based on the type requirement
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$inc": { "matrix.$[row]": 10 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$min": { "matrix.$[row]": 10 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$max": { "matrix.$[row]": 10 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$mul": { "matrix.$[row]": 2 }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$rename": { "matrix.$[row]": "arrayA.3" }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$set": { "matrix.$[row]": "updatedValue" }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- bit operator
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [0], [1] ] }',
    '{ "": { "$bit": { "matrix.$[row]": {"or": 5} }} }', '{}', '{ "": [{ "row": 0 }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- Check array value should also match in arrayFilters
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [11,12,13], [14,15,16] ] }',
    '{ "": { "$set": { "matrix.$[row]": [21,22,23] }} }', '{}', '{ "": [{ "row": [11,12,13] }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 1, "matrix" : [ [11,12,13], [14,15,16] ] }',
    '{ "": { "$set": { "matrix.$[row]": 33 }} }', '{}', '{ "": [{ "row": {"$size": 3} }] }', NULL::documentdb_core.bson, NULL::TEXT);

-- ========================================
-- Tests for $or/$and/$nor in arrayFilters
-- ========================================

-- ---- $or tests ----

-- $or on scalar array: match elements where value >= 200 OR value == 100
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200, 250] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": { "$gte": 200 } }, { "elem": 100 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $or on scalar array: no elements match
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200, 250] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": { "$gt": 300 } }, { "elem": 50 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $or on scalar array: all elements match
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200, 250] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": { "$gte": 100 } }, { "elem": { "$lt": 100 } }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $or with nested field paths on document array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "status": "active"}, {"type": "B", "status": "inactive"}, {"type": "C", "status": "active"}] }',
    '{ "": { "$set": { "items.$[item].status": "matched" }}}', '{}',
    '{ "": [{ "$or": [{ "item.type": "A" }, { "item.type": "C" }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $or with single element (degenerates to just the condition)
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": 150 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- $and tests ----

-- $and on scalar array: match elements where value >= 150 AND value < 250
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200, 250] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$and": [{ "elem": { "$gte": 150 } }, { "elem": { "$lt": 250 } }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $and with nested field paths on document array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "active": true, "count": 5}, {"type": "B", "active": true, "count": 15}, {"type": "C", "active": false, "count": 20}] }',
    '{ "": { "$set": { "items.$[item].matched": true }}}', '{}',
    '{ "": [{ "$and": [{ "item.active": true }, { "item.count": { "$gte": 10 } }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $and with single element
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$and": [{ "elem": { "$gte": 150 } }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- $nor tests ----

-- $nor on scalar array: match elements NOT (value == 100 OR value == 250)
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 150, 200, 250] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$nor": [{ "elem": 100 }, { "elem": 250 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $nor with document array fields
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "status": "active"}, {"type": "B", "status": "inactive"}, {"type": "C", "status": "active"}] }',
    '{ "": { "$set": { "items.$[item].status": "filtered" }}}', '{}',
    '{ "": [{ "$nor": [{ "item.type": "A" }, { "item.type": "B" }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Nested logical operators ----

-- $or wrapping $and (complex filter - the original user scenario)
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "games": [{"name": "G1", "themeId": "t1", "storeThemeId": "st1"}, {"name": "G2", "themeId": "t2", "storeThemeId": null}, {"name": "G3", "themeId": "t3", "storeThemeId": null}] }',
    '{ "": { "$set": { "games.$[g].name": "Updated" }}}', '{}',
    '{ "": [{ "$or": [{ "$and": [{ "g.storeThemeId": { "$ne": null } }, { "g.storeThemeId": "st1" }] }, { "g.themeId": "t2" }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $and wrapping $or
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "priority": 1, "active": true}, {"type": "B", "priority": 2, "active": false}, {"type": "C", "priority": 3, "active": true}, {"type": "D", "priority": 1, "active": false}] }',
    '{ "": { "$set": { "items.$[item].matched": true }}}', '{}',
    '{ "": [{ "$and": [{ "$or": [{ "item.type": "A" }, { "item.type": "C" }, { "item.type": "D" }] }, { "item.active": true }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- deeply nested: $or > $and > conditions
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "data": [{"x": 1, "y": 10}, {"x": 2, "y": 20}, {"x": 3, "y": 30}, {"x": 4, "y": 40}] }',
    '{ "": { "$set": { "data.$[d].matched": true }}}', '{}',
    '{ "": [{ "$or": [{ "$and": [{ "d.x": { "$gte": 1 } }, { "d.x": { "$lte": 2 } }] }, { "$and": [{ "d.y": { "$gte": 35 } }, { "d.y": { "$lte": 45 } }] }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Mixed logical operators with field paths at same level ----

-- $or mixed with a direct field condition (implicit AND between them)
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "active": true, "count": 5}, {"type": "B", "active": true, "count": 15}, {"type": "C", "active": false, "count": 20}] }',
    '{ "": { "$set": { "items.$[item].matched": true }}}', '{}',
    '{ "": [{ "$or": [{ "item.type": "A" }, { "item.type": "B" }], "item.active": true }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Multiple arrayFilters with logical operators ----

-- Two separate identifiers, one with $or
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "results": [{"type": "quiz", "answers": [20, 18, 15]}, {"type": "quiz", "answers": [18, 19, 16]}, {"type": "hw", "answers": [15, 14, 13]}] }',
    '{ "": { "$inc": { "results.$[typeElem].answers.$[ansScore]": 100 }}}', '{}',
    '{ "": [{ "$or": [{ "typeElem.type": "quiz" }, { "typeElem.type": "hw" }] }, { "ansScore": { "$gte": 18 } }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Update operators combined with logical arrayFilters ----

-- $inc with $or arrayFilter
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "scores": [10, 20, 30, 40, 50] }',
    '{ "": { "$inc": { "scores.$[s]": 100 }}}', '{}',
    '{ "": [{ "$or": [{ "s": 10 }, { "s": 50 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $unset with $and arrayFilter on document array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"type": "A", "temp": true, "val": 1}, {"type": "B", "temp": false, "val": 2}, {"type": "A", "temp": true, "val": 3}] }',
    '{ "": { "$unset": { "items.$[item].temp": "" }}}', '{}',
    '{ "": [{ "$and": [{ "item.type": "A" }, { "item.temp": true }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $mul with $nor arrayFilter
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "values": [2, 4, 6, 8, 10] }',
    '{ "": { "$mul": { "values.$[v]": 10 }}}', '{}',
    '{ "": [{ "$nor": [{ "v": 2 }, { "v": 10 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- $push with $or arrayFilter on nested array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "groups": [{"name": "X", "members": [1]}, {"name": "Y", "members": [2]}, {"name": "Z", "members": [3]}] }',
    '{ "": { "$push": { "groups.$[grp].members": 99 }}}', '{}',
    '{ "": [{ "$or": [{ "grp.name": "X" }, { "grp.name": "Z" }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Edge cases ----

-- Empty document (no array field) - should return unchanged
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1 }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": 100 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Array with single element matching $or
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [42] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": 42 }, { "elem": 99 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Empty array - should return unchanged
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": 100 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Null values in array elements - $or with null match
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "items": [{"val": null}, {"val": 1}, {"val": null}, {"val": 2}] }',
    '{ "": { "$set": { "items.$[item].val": 0 }}}', '{}',
    '{ "": [{ "$or": [{ "item.val": null }, { "item.val": 2 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- ---- Error cases ----

-- Error: $or with different identifiers across branches
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "elem": 100 }, { "other": 200 }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: $or with empty array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: $and with empty array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$and": [] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: $nor with empty array
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$nor": [] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: $or with non-array value
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": "invalid" }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: $or with non-document entries
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [42, 43] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: unsupported top-level operator ($expr) should still fail
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$expr": { "$gt": ["$elem", 100] } }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Error: nested $or with mismatched identifiers
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id": 1, "numbers": [100, 200] }',
    '{ "": { "$set": { "numbers.$[elem]": 999 }}}', '{}',
    '{ "": [{ "$or": [{ "$and": [{ "elem": 100 }] }, { "$and": [{ "wrong": 200 }] }] }] }',
    NULL::documentdb_core.bson, NULL::TEXT);

-- Existing tests above ran with GUC off (default).
-- Existing field-path arrayFilters should still work with GUC on (regression check).
SELECT documentdb_api_internal.update_bson_document(
    '{"_id": 1, "numbers": [ 100, 200 ] }','{ "": { "$set": { "numbers.$[numElem]": 300 }}}', '{}', '{ "": [{ "numElem": 100 }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "scores" : [ 150, 210, 200, 180, 202 ], "age": 16 }','{ "": { "$set": { "scores.$[scoreElem]": 200 }}}', '{}', '{ "": [{ "scoreElem": { "$gte": 200 } }] }', NULL::documentdb_core.bson, NULL::TEXT);
SELECT documentdb_api_internal.update_bson_document(
    '{ "_id" : 3, "metrics" : [ { "value": 58, "max": 136, "avg": 66, "dev": 88}, { "value": 96, "max": 176, "avg": 99, "dev": 75}, { "value": 68, "max":168, "avg": 86, "dev": 83 } ] }',
    '{ "": { "$set": { "metrics.$[metricElem].avg": 100 }}}', '{}', '{ "": [{ "metricElem.value": { "$gte": 60 } }] }', NULL::documentdb_core.bson, NULL::TEXT);

