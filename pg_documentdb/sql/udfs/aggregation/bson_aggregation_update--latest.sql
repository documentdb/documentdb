-- Copyright (c) Microsoft Corporation.
-- SPDX-License-Identifier: MIT

DROP FUNCTION IF EXISTS __API_CATALOG_SCHEMA__.bson_aggregation_update;

-- This wrapper carries an update specification until the planner replaces it.
CREATE OR REPLACE FUNCTION __API_CATALOG_SCHEMA__.bson_aggregation_update(
    databaseName text,
    updateSpec __CORE_SCHEMA__.bson,
    OUT document __CORE_SCHEMA__.bson)
 RETURNS SETOF __CORE_SCHEMA__.bson
 LANGUAGE c
 IMMUTABLE PARALLEL SAFE STRICT
AS 'MODULE_PATHNAME', $function$command_bson_aggregation_update$function$;
