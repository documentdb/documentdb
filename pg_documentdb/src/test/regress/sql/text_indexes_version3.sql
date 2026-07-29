SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core;
SET documentdb.next_collection_id TO 8100;
SET documentdb.next_collection_index_id TO 8100;
SET documentdb_core.bsonUseEJson TO on;
SET max_parallel_workers_per_gather TO 0;

---- textIndexVersion parsing: invalid values still rejected ----
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "c0", "indexes": [{"key": {"a": "text"}, "name": "t0", "textIndexVersion": 1}]}', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "c0", "indexes": [{"key": {"a": "text"}, "name": "t0", "textIndexVersion": "3"}]}', true);

---- GUC off (default): version 3 accepted, built with v2 semantics + NOTICE ----
SET documentdb.enableTextIndexVersion3 TO off;
SELECT documentdb_api.create_collection('textv3db', 'shimcoll');
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "shimcoll", "indexes": [{"key": {"a": "text"}, "name": "shim_text", "textIndexVersion": 3}]}', true);
SELECT documentdb_api.insert_one('textv3db', 'shimcoll', '{"_id": 1, "a": "Café"}');
-- v2 semantics with english config: no diacritic folding -> no match
SELECT document FROM documentdb_api.collection('textv3db', 'shimcoll')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "cafe"}}';
-- accented search matches the accented document
SELECT document FROM documentdb_api.collection('textv3db', 'shimcoll')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "café"}}';

---- GUC on: full version 3 (diacritic folding via unaccent) ----
SET documentdb.enableTextIndexVersion3 TO on;
SELECT documentdb_api.create_collection('textv3db', 'cities');
SELECT documentdb_api.insert_one('textv3db', 'cities', '{"_id": 1, "name": "São Paulo"}');
SELECT documentdb_api.insert_one('textv3db', 'cities', '{"_id": 2, "name": "Bragança Paulista"}');
SELECT documentdb_api.insert_one('textv3db', 'cities', '{"_id": 3, "name": "Coração de Jesus"}');
SELECT documentdb_api.insert_one('textv3db', 'cities', '{"_id": 4, "name": "Brasilia"}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "cities", "indexes": [{"key": {"name": "text"}, "name": "name_text_v3", "textIndexVersion": 3, "default_language": "portuguese"}]}', true);

-- unaccented searches find accented documents
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "braganca"}}' ORDER BY bson_get_value(document, '_id');
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "coracao"}}' ORDER BY bson_get_value(document, '_id');
-- 'sao': in v2 this NEVER matches ('São' is a portuguese stopword and is
-- dropped from the index); v3 folds before the dictionary, so it works.
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "sao"}}' ORDER BY bson_get_value(document, '_id');
-- accented searches are folded on the query side too
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "bragança"}}' ORDER BY bson_get_value(document, '_id');
-- no false positives
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "curitiba"}}' ORDER BY bson_get_value(document, '_id');

---- english config: the stemmer never folds accents, v3 is what makes it work ----
SELECT documentdb_api.create_collection('textv3db', 'products');
SELECT documentdb_api.insert_one('textv3db', 'products', '{"_id": 1, "desc": "Café com Açúcar"}');
SELECT documentdb_api.insert_one('textv3db', 'products', '{"_id": 2, "desc": "Chocolate amargo"}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "products", "indexes": [{"key": {"desc": "text"}, "name": "desc_text_v3", "textIndexVersion": 3, "default_language": "english"}]}', true);
SELECT document FROM documentdb_api.collection('textv3db', 'products')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "cafe"}}' ORDER BY bson_get_value(document, '_id');
SELECT document FROM documentdb_api.collection('textv3db', 'products')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "acucar"}}' ORDER BY bson_get_value(document, '_id');

---- per-index semantics: a v2 index created while the GUC is on stays v2 ----
SELECT documentdb_api.create_collection('textv3db', 'legacy');
SELECT documentdb_api.insert_one('textv3db', 'legacy', '{"_id": 1, "desc": "Café"}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "legacy", "indexes": [{"key": {"desc": "text"}, "name": "desc_text_v2", "textIndexVersion": 2, "default_language": "english"}]}', true);
-- unaccented search must NOT match on the v2 index even with the GUC on
SELECT document FROM documentdb_api.collection('textv3db', 'legacy')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "cafe"}}';
SELECT document FROM documentdb_api.collection('textv3db', 'legacy')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "café"}}';

---- weighted multi-path v3 index ----
SELECT documentdb_api.create_collection('textv3db', 'articles');
SELECT documentdb_api.insert_one('textv3db', 'articles', '{"_id": 1, "title": "Ação e Reação", "body": "história sem graça"}');
SELECT documentdb_api.insert_one('textv3db', 'articles', '{"_id": 2, "title": "Sem graça", "body": "uma ação qualquer aqui"}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('textv3db', '{"createIndexes": "articles", "indexes": [{"key": {"title": "text", "body": "text"}, "name": "art_text_v3", "textIndexVersion": 3, "weights": {"title": 10, "body": 1}, "default_language": "portuguese"}]}', true);
-- both documents match via folding across both weighted paths
SELECT bson_get_value(document, '_id') AS doc_id FROM documentdb_api.collection('textv3db', 'articles')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "acao"}}'
ORDER BY bson_get_value(document, '_id');

---- updates keep folded terms in sync ----
SELECT documentdb_api.insert_one('textv3db', 'cities', '{"_id": 5, "name": "Florianopolis"}');
SELECT documentdb_api.update('textv3db', '{"update": "cities", "updates": [{"q": {"_id": 5}, "u": {"$set": {"name": "Florianópolis"}}}]}');
SELECT document FROM documentdb_api.collection('textv3db', 'cities')
WHERE document OPERATOR(documentdb_api_catalog.@@) '{"$text": {"$search": "florianopolis"}}' ORDER BY bson_get_value(document, '_id');

---- cleanup ----
SELECT documentdb_api.drop_collection('textv3db', 'shimcoll');
SELECT documentdb_api.drop_collection('textv3db', 'cities');
SELECT documentdb_api.drop_collection('textv3db', 'products');
SELECT documentdb_api.drop_collection('textv3db', 'legacy');
SELECT documentdb_api.drop_collection('textv3db', 'articles');
RESET documentdb.enableTextIndexVersion3;
