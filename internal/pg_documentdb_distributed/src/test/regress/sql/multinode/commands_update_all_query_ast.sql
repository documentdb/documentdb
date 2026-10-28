-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
SET citus.next_shard_id TO 267101000;
SET documentdb.next_collection_id TO 26710100;
SET documentdb.next_collection_index_id TO 26710100;
SET documentdb.enableSchemaValidation TO ON;
SET documentdb.enableBypassDocumentValidation TO ON;
SET documentdb_core.enableCollation TO ON;
SET documentdb.skipFailOnCollation TO OFF;
SET documentdb.enable_support_function_id_pushdown TO OFF;
SET citus.propagate_set_commands TO 'local';
SET citus.max_cached_conns_per_worker TO 0;

SELECT documentdb_api.create_collection('update_all_ast_remote', 'remote');
CALL documentdb_distributed_test_helpers.place_collection_on_node('update_all_ast_remote', 'remote', 1);
SELECT documentdb_api.create_collection('update_all_ast_remote', 'sharded');
SELECT documentdb_api.shard_collection('update_all_ast_remote', 'sharded', '{"tenant":"hashed"}', false);
SELECT documentdb_api.create_collection('update_all_ast_remote', 'string_sharded');
SELECT documentdb_api.shard_collection('update_all_ast_remote', 'string_sharded', '{"tenant":"hashed"}', false);
SELECT documentdb_api.create_collection_view('update_all_ast_remote', '{"create":"validated","validator":{"$jsonSchema":{"properties":{"value":{"bsonType":"int"}}}},"validationLevel":"strict","validationAction":"error"}');
CALL documentdb_distributed_test_helpers.place_collection_on_node('update_all_ast_remote', 'validated', 1);
SELECT documentdb_api.create_collection_view('update_all_ast_remote', '{"create":"validated_sharded","enableUpdateDescription":true,"validator":{"$jsonSchema":{"properties":{"value":{"bsonType":"int"}}}},"validationLevel":"strict","validationAction":"error"}');
SELECT documentdb_api.shard_collection('update_all_ast_remote', 'validated_sharded', '{"tenant":"hashed"}', false);

-- Check placements rather than treating a distributed table as proof of
-- remote execution. Validated unsharded writes must use the schema worker route.
SELECT c.collection_name, bool_and(p.groupid <> 0) AS all_placements_remote
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard s ON s.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement p ON p.shardid = s.shardid AND p.shardstate = 1
WHERE c.database_name = 'update_all_ast_remote' AND c.collection_name IN ('remote', 'validated')
GROUP BY c.collection_name ORDER BY c.collection_name;
SELECT c.collection_name, count(DISTINCT s.shardid) > 1 AS multiple_shards,
       bool_or(p.groupid <> 0) AS has_remote_placement
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard s ON s.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement p ON p.shardid = s.shardid AND p.shardstate = 1
WHERE c.database_name = 'update_all_ast_remote' AND c.collection_name IN ('sharded', 'string_sharded', 'validated_sharded')
GROUP BY c.collection_name ORDER BY c.collection_name;

CREATE TEMP TABLE remote_update_all_cases (
    seq int PRIMARY KEY, label text, target text, command bson,
    matched int, modified int, fails bool DEFAULT false
);
INSERT INTO remote_update_all_cases VALUES
 (1, 'remote mixed ID residual', 'remote', '{"update":"remote","updates":[{"q":{"_id":1,"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (2, 'remote no-op', 'remote', '{"update":"remote","updates":[{"q":{"group":"x"},"u":{"$set":{"group":"x"}},"multi":true}]}', 2, 0, false),
 (3, 'remote residual rejects ID', 'remote', '{"update":"remote","updates":[{"q":{"_id":1,"group":"missing"},"u":{"$inc":{"value":1}},"multi":true}]}', 0, 0, false),
 (4, 'sharded empty predicate', 'sharded', '{"update":"sharded","updates":[{"q":{},"u":{"$inc":{"value":1}},"multi":true}]}', 3, 3, false),
 (5, 'sharded collated positional', 'sharded', '{"update":"sharded","updates":[{"q":{"label":"CAT","items.label":"CAT"},"u":{"$inc":{"items.$.qty":10}},"multi":true,"collation":{"locale":"en","strength":2}}]}', 2, 2, false),
 (6, 'sharded let and collated expression', 'sharded', '{"update":"sharded","let":{"wanted":{"$literal":"CAT"},"increment":2},"updates":[{"q":{"$expr":{"$eq":["$label","$$wanted"]}},"u":[{"$set":{"value":{"$add":["$value","$$increment"]},"equal":{"$eq":["$label","$$wanted"]}}}],"multi":true,"collation":{"locale":"en","strength":2}}]}', 2, 2, false),
 (7, 'remote schema valid', 'validated', '{"update":"validated","updates":[{"q":{"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 2, 2, false),
 (8, 'remote schema rollback', 'validated', '{"update":"validated","updates":[{"q":{"group":"x"},"u":[{"$set":{"value":{"$cond":[{"$eq":["$_id",2]},"invalid",11]}}}],"multi":true}]}', NULL, NULL, true),
 (9, 'remote schema bypass', 'validated', '{"update":"validated","bypassDocumentValidation":true,"updates":[{"q":{"group":"x"},"u":{"$set":{"value":"bypassed"}},"multi":true}]}', 2, 2, false),
 (10, 'sharded schema description let', 'validated_sharded', '{"update":"validated_sharded","let":{"increment":2},"updates":[{"q":{"label":"CAT"},"u":[{"$set":{"value":{"$add":["$value","$$increment"]},"equal":{"$eq":["$label","CAT"]}}}],"multi":true,"collation":{"locale":"en","strength":2}}]}', 2, 2, false),
 (11, 'sharded schema rollback', 'validated_sharded', '{"update":"validated_sharded","updates":[{"q":{"group":"x"},"u":[{"$set":{"value":{"$cond":[{"$eq":["$_id",2]},"invalid",11]}}}],"multi":true}]}', NULL, NULL, true),
 (12, 'sharded schema no-op', 'validated_sharded', '{"update":"validated_sharded","updates":[{"q":{"group":"x"},"u":{"$set":{"group":"x"}},"multi":true}]}', 2, 0, false),
 (13, 'remote protected ID only', 'remote', '{"update":"remote","updates":[{"q":{"_id":1},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (14, 'sharded collated array filter', 'sharded', '{"update":"sharded","updates":[{"q":{"label":"CAT"},"u":{"$set":{"items.$[item].seen":true},"$addToSet":{"tags":"CAT"}},"arrayFilters":[{"item.label":"CAT"}],"multi":true,"collation":{"locale":"en","strength":2}}]}', 2, 2, false),
 (15, 'targeted mixed ID', 'sharded', '{"update":"sharded","updates":[{"q":{"tenant":1,"_id":1,"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (16, 'targeted residual rejection', 'sharded', '{"update":"sharded","updates":[{"q":{"tenant":1,"_id":1,"group":"missing"},"u":{"$inc":{"value":1}},"multi":true}]}', 0, 0, false),
 (17, 'schema scatter mixed ID', 'validated_sharded', '{"update":"validated_sharded","updates":[{"q":{"_id":1,"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (18, 'schema targeted mixed ID', 'validated_sharded', '{"update":"validated_sharded","updates":[{"q":{"tenant":1,"_id":1,"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (19, 'schema targeted without ID', 'validated_sharded', '{"update":"validated_sharded","updates":[{"q":{"tenant":2,"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (20, 'scatter ID range with residual', 'sharded', '{"update":"sharded","updates":[{"q":{"_id":{"$gte":2},"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (21, 'shard membership with residual', 'sharded', '{"update":"sharded","updates":[{"q":{"tenant":{"$in":[1,3]},"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (22, 'disjunctive shard and ID filters', 'sharded', '{"update":"sharded","updates":[{"q":{"$or":[{"tenant":1,"_id":1},{"tenant":3,"_id":3}]},"u":{"$inc":{"value":1}},"multi":true}]}', 2, 2, false),
 (23, 'nested targeted ID filters', 'sharded', '{"update":"sharded","updates":[{"q":{"$and":[{"tenant":2},{"_id":2},{"group":"x"}]},"u":{"$inc":{"value":1}},"multi":true}]}', 1, 1, false),
 (24, 'remote empty predicate', 'remote', '{"update":"remote","updates":[{"q":{},"u":{"$inc":{"value":1}},"multi":true}]}', 3, 3, false),
 (25, 'collated shard key scatter', 'string_sharded', '{"update":"string_sharded","updates":[{"q":{"tenant":"CAT"},"u":{"$inc":{"value":1}},"multi":true,"collation":{"locale":"en","strength":2}}]}', 2, 2, false),
 (26, 'collated shard key mixed ID', 'string_sharded', '{"update":"string_sharded","updates":[{"q":{"tenant":"CAT","_id":2},"u":{"$inc":{"value":1}},"multi":true,"collation":{"locale":"en","strength":2}}]}', 1, 1, false);

CREATE TEMP TABLE remote_update_all_results (
    pass text, seq int, result text, success bool, error text, documents text[],
    PRIMARY KEY (pass, seq)
);
BEGIN;
SET LOCAL citus.enable_ddl_propagation TO OFF;
CREATE FUNCTION pg_temp.run_remote_update_all_cases(pass_name text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    test_case record;
    response bson;
    succeeded bool;
    failure text;
    before_docs text[];
    after_docs text[];
BEGIN
    FOR test_case IN SELECT * FROM remote_update_all_cases ORDER BY seq LOOP
        PERFORM documentdb_api.delete('update_all_ast_remote',
            format('{"delete":"%s","deletes":[{"q":{},"limit":0}]}', test_case.target)::bson);
        PERFORM documentdb_api.insert('update_all_ast_remote', format(
            '{"insert":"%s","documents":[
             {"_id":1,"tenant":%s,"group":"x","label":"Cat","value":10,"tags":["Cat"],"items":[{"label":"Cat","qty":1},{"label":"Dog","qty":5}]},
             {"_id":2,"tenant":%s,"group":"x","label":"cat","value":20,"tags":["cat"],"items":[{"label":"cat","qty":2},{"label":"Dog","qty":7}]},
             {"_id":3,"tenant":%s,"group":"y","label":"dog","value":30,"tags":["dog"],"items":[{"label":"dog","qty":3}]}]}',
            test_case.target,
            CASE WHEN test_case.target = 'string_sharded' THEN '"Cat"' ELSE '1' END,
            CASE WHEN test_case.target = 'string_sharded' THEN '"cat"' ELSE '2' END,
            CASE WHEN test_case.target = 'string_sharded' THEN '"dog"' ELSE '3' END)::bson);
        SELECT array_agg(document::text ORDER BY object_id) INTO before_docs
        FROM documentdb_api.collection('update_all_ast_remote', test_case.target);
        response := NULL;
        succeeded := NULL;
        failure := NULL;
        BEGIN
            SELECT p_result, p_success INTO response, succeeded
            FROM documentdb_api.update('update_all_ast_remote', test_case.command);
        EXCEPTION WHEN OTHERS THEN
            failure := SQLSTATE || ': ' || SQLERRM;
        END;
        SELECT array_agg(document::text ORDER BY object_id) INTO after_docs
        FROM documentdb_api.collection('update_all_ast_remote', test_case.target);
        IF test_case.fails IS DISTINCT FROM (failure IS NOT NULL OR succeeded IS NOT TRUE) THEN
            RAISE EXCEPTION 'Unexpected outcome for %: %, %', test_case.label, response, failure;
        END IF;
        IF NOT test_case.fails AND (response @@ format(
            '{"n":%s,"nModified":%s}', test_case.matched, test_case.modified)::bson) IS NOT TRUE THEN
            RAISE EXCEPTION 'Unexpected counts for %: %', test_case.label, response;
        END IF;
        IF test_case.fails AND (response @@
            '{"n":0,"nModified":0,"writeErrors":{"$elemMatch":{"errmsg":"Document failed validation"}}}'::bson) IS NOT TRUE THEN
            RAISE EXCEPTION 'Expected validation failure for %: %, %', test_case.label, response, failure;
        END IF;
        IF (test_case.fails OR test_case.modified = 0) AND before_docs IS DISTINCT FROM after_docs THEN
            RAISE EXCEPTION 'Unexpected document changes for %', test_case.label;
        END IF;
        INSERT INTO remote_update_all_results VALUES
            (pass_name, test_case.seq, response::text, succeeded, failure, after_docs);
    END LOOP;
    RETURN (SELECT count(*)::int FROM remote_update_all_cases);
END;
$$;

-- These defaults affect only this disposable test cluster. A coordinator SET
-- alone does not opt workers in; uncached connections load the worker defaults.
CREATE FUNCTION pg_temp.configure_update_all_workers(enabled bool, pushdown bool, commutative bool, id_pushdown bool DEFAULT false)
RETURNS bool LANGUAGE SQL AS $$
    SELECT bool_and(success) FROM run_command_on_workers(format(
        'SET LOCAL citus.enable_ddl_propagation TO OFF;
         ALTER DATABASE postgres SET documentdb.enable_update_query_ast = %L;
         ALTER DATABASE postgres SET documentdb.enable_update_many_worker_pushdown = %L;
         ALTER DATABASE postgres SET documentdb.enableCommutativeUpdateMany = %L;
         ALTER DATABASE postgres SET documentdb.enable_support_function_id_pushdown = %L;
         ALTER DATABASE postgres SET documentdb.enableSchemaValidation = on;
         ALTER DATABASE postgres SET documentdb.enableBypassDocumentValidation = on;
         ALTER DATABASE postgres SET documentdb_core.enableCollation = on;',
        enabled, pushdown, commutative, id_pushdown));
$$;
COMMIT;

PREPARE remote_update_all_prepared(text) AS SELECT pg_temp.run_remote_update_all_cases($1);
SELECT pg_temp.configure_update_all_workers(false, false, false);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO OFF;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SET LOCAL documentdb.enableCommutativeUpdateMany TO OFF;
EXECUTE remote_update_all_prepared('legacy_wrapper');
COMMIT;
SELECT pg_temp.configure_update_all_workers(true, false, false);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO ON;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SET LOCAL documentdb.enableCommutativeUpdateMany TO OFF;
SELECT bool_and(success AND result = 'on') AS worker_ast_enabled
FROM run_command_on_workers('SHOW documentdb.enable_update_query_ast');
EXECUTE remote_update_all_prepared('native_wrapper');
COMMIT;
SELECT pg_temp.configure_update_all_workers(false, true, true);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO OFF;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO ON;
SET LOCAL documentdb.enableCommutativeUpdateMany TO ON;
EXECUTE remote_update_all_prepared('legacy_worker');
COMMIT;
SELECT pg_temp.configure_update_all_workers(true, true, true);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO ON;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO ON;
SET LOCAL documentdb.enableCommutativeUpdateMany TO ON;
SELECT bool_and(success AND result = 'on') AS worker_native_pushdown_enabled
FROM (
    SELECT success, result FROM run_command_on_workers('SHOW documentdb.enable_update_query_ast')
    UNION ALL
    SELECT success, result FROM run_command_on_workers('SHOW documentdb.enable_update_many_worker_pushdown')
    UNION ALL
    SELECT success, result FROM run_command_on_workers('SHOW documentdb_core.enableCollation')
) worker_settings;
EXECUTE remote_update_all_prepared('native_worker');
COMMIT;
SELECT pg_temp.configure_update_all_workers(true, false, false, true);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO ON;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SET LOCAL documentdb.enableCommutativeUpdateMany TO OFF;
SET LOCAL documentdb.enable_support_function_id_pushdown TO ON;
EXECUTE remote_update_all_prepared('native_wrapper_id_pushdown');
COMMIT;
SELECT pg_temp.configure_update_all_workers(true, true, true, true);
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO ON;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO ON;
SET LOCAL documentdb.enableCommutativeUpdateMany TO ON;
SET LOCAL documentdb.enable_support_function_id_pushdown TO ON;
EXECUTE remote_update_all_prepared('native_worker_id_pushdown');
COMMIT;

DO $$
BEGIN
    IF (SELECT count(*) FROM remote_update_all_results) <> 6 * (SELECT count(*) FROM remote_update_all_cases)
       OR EXISTS (
           SELECT 1 FROM remote_update_all_results a JOIN remote_update_all_results b USING (seq)
           WHERE a.pass = 'legacy_wrapper' AND b.pass <> 'legacy_wrapper' AND
                 ROW(a.result, a.success, a.error, a.documents) IS DISTINCT FROM
                 ROW(b.result, b.success, b.error, b.documents)
       ) THEN
        RAISE EXCEPTION 'Remote native update-all response or document parity failed';
    END IF;
END;
$$;

SELECT c.label, b.pass,
       ROW(a.result, a.success, a.error, a.documents) IS NOT DISTINCT FROM
       ROW(b.result, b.success, b.error, b.documents) AS exact_parity
FROM remote_update_all_cases c
JOIN remote_update_all_results a ON a.seq = c.seq AND a.pass = 'legacy_wrapper'
JOIN remote_update_all_results b ON b.seq = c.seq AND b.pass <> 'legacy_wrapper'
ORDER BY c.seq, b.pass;
SELECT c.label, r.result, r.success, r.error
FROM remote_update_all_cases c JOIN remote_update_all_results r USING (seq)
WHERE r.pass = 'legacy_wrapper' ORDER BY c.seq;
SELECT c.label, r.documents
FROM remote_update_all_cases c JOIN remote_update_all_results r USING (seq)
WHERE r.pass = 'native_worker' AND c.seq IN (5, 6, 8, 10, 11, 14)
ORDER BY c.seq;

-- Commutative-write scoping must be restored even when an update errors.
BEGIN;
SET LOCAL documentdb.enable_update_query_ast TO ON;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SET LOCAL documentdb.enableCommutativeUpdateMany TO ON;
SET LOCAL citus.all_modifications_commutative TO OFF;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"sharded","updates":[{"q":{"group":"x"},"u":{"$inc":{"value":1}},"multi":true}]}');
SELECT NOT current_setting('citus.all_modifications_commutative')::bool AS restored_after_success;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"sharded","updates":[{"q":{"group":"x"},"u":{"$inc":{"group":1}},"multi":true}]}');
SELECT NOT current_setting('citus.all_modifications_commutative')::bool AS restored_after_error;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"sharded","updates":[{"q":{"group":"x"},"u":{"$inc":{"value":0}},"multi":true}]}');
SELECT NOT current_setting('citus.all_modifications_commutative')::bool AS restored_after_recovery;
ROLLBACK;

-- Autocommit requests use coordinator-local metadata rather than a worker's
-- explicit physical shard OID.
SELECT shouldhaveshards AS coordinator_had_shards FROM pg_dist_node
WHERE groupid = 0 AND noderole = 'primary' \gset
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', true)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
SELECT documentdb_api.create_collection('update_all_ast_remote', 'coordinator_local');
CALL documentdb_distributed_test_helpers.place_collection_on_node('update_all_ast_remote', 'coordinator_local', 0);
SELECT count(DISTINCT s.shardid) = 1 AND bool_and(p.groupid = 0) AS single_local_shard
FROM documentdb_api_catalog.collections c
JOIN pg_dist_shard s ON s.logicalrelid = ('documentdb_data.documents_' || c.collection_id)::regclass
JOIN pg_dist_placement p ON p.shardid = s.shardid AND p.shardstate = 1
WHERE c.database_name = 'update_all_ast_remote' AND c.collection_name = 'coordinator_local';
SELECT documentdb_api.insert('update_all_ast_remote', '{"insert":"coordinator_local","documents":[{"_id":1,"value":10,"label":"cat"},{"_id":2,"value":20,"label":"CAT"}]}');
SET documentdb.useLocalExecutionShardQueries TO ON;
-- A parent-table plan executes in another backend and loses the local
-- modified-document counter, despite the shard being on this node.
SET citus.enable_local_execution TO OFF;
SET documentdb.enable_update_many_worker_pushdown TO ON;
SET documentdb.enable_update_query_ast TO OFF;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{},"u":{"$inc":{"value":1}},"multi":true}]}');
SET documentdb.enable_update_query_ast TO ON;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{},"u":{"$inc":{"value":1}},"multi":true}]}');
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{"value":12},"u":{"$set":{"value":12}},"multi":true}]}');
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{},"u":{"$set":{"value":12}},"multi":true}]}');
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{"value":99},"u":{"$inc":{"value":1}},"multi":true}]}');
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{"label":"Cat"},"u":{"$inc":{"value":1}},"multi":true,"collation":{"locale":"en","strength":2}}]}');
SET documentdb.enable_update_many_worker_pushdown TO OFF;
SELECT documentdb_api.update('update_all_ast_remote', '{"update":"coordinator_local","updates":[{"q":{},"u":{"$inc":{"value":1}},"multi":true}]}');
SELECT document FROM documentdb_api.collection('update_all_ast_remote', 'coordinator_local') ORDER BY object_id;
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'coordinator_local');
SELECT citus_set_node_property(nodename, nodeport, 'shouldhaveshards', :'coordinator_had_shards'::boolean)
FROM pg_dist_node WHERE groupid = 0 AND noderole = 'primary';
RESET citus.enable_local_execution;
RESET documentdb.useLocalExecutionShardQueries;
RESET documentdb.enable_update_query_ast;
RESET documentdb.enable_update_many_worker_pushdown;

DEALLOCATE remote_update_all_prepared;
SELECT bool_and(success) AS worker_defaults_restored FROM run_command_on_workers(
    'SET LOCAL citus.enable_ddl_propagation TO OFF;
     ALTER DATABASE postgres RESET documentdb.enable_update_query_ast;
     ALTER DATABASE postgres RESET documentdb.enable_update_many_worker_pushdown;
     ALTER DATABASE postgres RESET documentdb.enableCommutativeUpdateMany;
     ALTER DATABASE postgres RESET documentdb.enable_support_function_id_pushdown;
     ALTER DATABASE postgres RESET documentdb.enableSchemaValidation;
     ALTER DATABASE postgres RESET documentdb.enableBypassDocumentValidation;
     ALTER DATABASE postgres RESET documentdb_core.enableCollation;');
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'remote');
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'sharded');
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'string_sharded');
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'validated');
SELECT documentdb_api.drop_collection('update_all_ast_remote', 'validated_sharded');
RESET documentdb.enableSchemaValidation;
RESET documentdb.enableBypassDocumentValidation;
RESET documentdb_core.enableCollation;
RESET documentdb.skipFailOnCollation;
RESET documentdb.enable_support_function_id_pushdown;
RESET citus.propagate_set_commands;
RESET citus.max_cached_conns_per_worker;
