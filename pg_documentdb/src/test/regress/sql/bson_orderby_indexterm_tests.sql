/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 */

SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.next_collection_id TO 900;
SET documentdb.next_collection_index_id TO 900;

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": 1 }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": null }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ] }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ] }', '{ "a": -1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ { "b": 0 }, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": -1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, 2, 3 ] }', '{ "a": 1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, 2, 3 ] }', '{ "a": -1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ { "b": 0 }, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, { "b": 1 }, { "b": 2 } ] }', '{ "a.b": -1 }'));

-- try with collation
set documentdb_core.enableCollation to on;
SELECT bsonindexterm_to_bson(bson_orderby_index('{ }', '{ "a": 1 }', 'en-u-ks-level1'));

-- case insensitive - picks cat
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ "Cat", "dog", "elephant" ] }', '{ "a": 1 }', 'en-u-ks-level1'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ "Cat", "dog", "elephant" ] }', '{ "a": 1 }', 'en-u-ks-level1'));

-- case sensitive (default) - picks Dog
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ "cat", "Dog", "elephant" ] }', '{ "a": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ "cat", "Dog", "elephant" ] }', '{ "a": 1 }'));

-- try with a composite index term
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": 1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": -1 }'));

SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": 1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": 1 }'));
SELECT bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [ 1, 2, 3 ], "b": 5 }', '{ "a": -1, "b": -1 }'));


SELECT bsonindexterm_to_bson('{ "a": [ 1, 2, 3 ], "b": 5 }' |<> '{ "a": 1, "b": 1 }');
SELECT bsonindexterm_to_bson('{ "a": [ 1, 2, 3 ], "b": 5 }' <>| '{ "a": 1, "b": 1 }');

-- Reuse the sort options without retaining terms from earlier documents.
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index(document, '{ "a": 1, "b": -1 }')) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse(document, '{ "a": 1, "b": -1 }')) AS last
FROM (VALUES
    (1, '{ "a": [3, 1, 2], "b": 5 }'::bson),
    (2, '{ "a": 7, "b": 2 }'::bson),
    (3, '{ "b": 4 }'::bson),
    (4, '{ "a": [], "b": 1 }'::bson)
) AS inputs(id, document)
ORDER BY id;

-- A varying sort specification must not reuse the first row's options.
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index('{ "a": [3, 1], "b": 2 }', sort_spec)) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": [3, 1], "b": 2 }', sort_spec)) AS last
FROM (VALUES
    (1, '{ "a": 1 }'::bson),
    (2, '{ "a": -1 }'::bson),
    (3, '{ "b": 1 }'::bson),
    (4, '{ "a": 1, "b": -1 }'::bson)
) AS inputs(id, sort_spec)
ORDER BY id;

SELECT id,
       bsonindexterm_to_bson(bson_orderby_index(document, '{ "a.b": 1 }', 'en-u-ks-level1')) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse(document, '{ "a.b": 1 }', 'en-u-ks-level1')) AS last
FROM (VALUES
    (1, '{ "a": [{ "b": "z" }, { "b": "A" }] }'::bson),
    (2, '{ "a": { "b": ["B", "a"] } }'::bson),
    (3, '{ }'::bson)
) AS inputs(id, document)
ORDER BY id;

-- Collation can vary even when the sort specification is constant.
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index('{ "a": ["B", "a"] }', '{ "a": 1 }', collation_name)) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse('{ "a": ["B", "a"] }', '{ "a": 1 }', collation_name)) AS last
FROM (VALUES
    (1, 'en-u-ks-level1'),
    (2, ''),
    (3, 'en-u-ks-level1')
) AS inputs(id, collation_name)
ORDER BY id;

SET plan_cache_mode TO force_generic_plan;
PREPARE orderby_index_options(bson, text) AS
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index(document, $1, $2)) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse(document, $1, $2)) AS last
FROM (VALUES
    (1, '{ "a": ["B", "a"], "b": 3 }'::bson),
    (2, '{ "a": ["Z", "c"], "b": 1 }'::bson)
) AS inputs(id, document)
ORDER BY id;
EXECUTE orderby_index_options('{ "a": 1 }', 'en-u-ks-level1');
EXECUTE orderby_index_options('{ "b": -1 }', '');
EXECUTE orderby_index_options('{ "a": -1 }', '');
DEALLOCATE orderby_index_options;
RESET plan_cache_mode;

-- Correlated terms and missing-path state must be independent for each document.
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index(document, '{ "a.b": 1, "a.c": -1 }')) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse(document, '{ "a.b": 1, "a.c": -1 }')) AS last
FROM (VALUES
    (1, '{ "a": [{"b": 2, "c": 9}, {"b": 1, "c": 4}] }'::bson),
    (2, '{ "a": {"b": 7, "c": 3} }'::bson),
    (3, '{ "a": [{"b": 5}, {"c": 8}] }'::bson),
    (4, '{ "a": [] }'::bson),
    (5, '{ "a": [{"b": 3, "c": 6}, {"b": 1, "c": 2}] }'::bson)
) AS inputs(id, document)
ORDER BY id;

-- Term metadata must honor a setting changed by a volatile argument expression.
SELECT id,
       bsonindexterm_to_bson(bson_orderby_index(
           ('{ "a": [3, 1], "setting": "' ||
            set_config('documentdb.enableValueOnlyIndexTerms', enabled, false) || '" }')::bson,
           '{ "a": 1 }')) AS first,
       bsonindexterm_to_bson(bson_orderby_index_reverse(
           ('{ "a": [3, 1], "setting": "' ||
            set_config('documentdb.enableValueOnlyIndexTerms', enabled, false) || '" }')::bson,
           '{ "a": 1 }')) AS last
FROM (VALUES (1, 'off'), (2, 'on'), (3, 'off')) AS inputs(id, enabled)
ORDER BY id;
RESET documentdb.enableValueOnlyIndexTerms;
