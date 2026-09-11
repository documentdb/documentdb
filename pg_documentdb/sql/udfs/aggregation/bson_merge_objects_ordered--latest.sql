CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_merge_objects_ordered_transition(internal, __CORE_SCHEMA_V2__.bson)
 RETURNS internal
 LANGUAGE c
 STABLE
 PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$bson_merge_objects_ordered_transition$function$;

CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.bson_merge_objects_ordered_final(internal)
 RETURNS __CORE_SCHEMA_V2__.bson
 LANGUAGE c
 STABLE
 PARALLEL SAFE
AS 'MODULE_PATHNAME', $function$bson_merge_objects_ordered_final$function$;

/* No combine function: merging partial states would lose global field order. */
CREATE OR REPLACE AGGREGATE __API_SCHEMA_INTERNAL_V2__.bson_merge_objects_ordered(__CORE_SCHEMA_V2__.bson)
(
    SFUNC = __API_SCHEMA_INTERNAL_V2__.bson_merge_objects_ordered_transition,
    FINALFUNC = __API_SCHEMA_INTERNAL_V2__.bson_merge_objects_ordered_final,
    STYPE = internal,
    FINALFUNC_MODIFY = READ_WRITE,
    PARALLEL = SAFE
);
