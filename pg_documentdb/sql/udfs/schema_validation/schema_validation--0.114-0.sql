
/* apply schema validation while data updating */
/* Original version with bytea validator state - introduced in 0.24.0 */
/* Retained here so the latest file reflects the full set of live signatures.
 * Still selected at runtime for older cluster versions (see commands/update.c). */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.schema_validation_against_update(
    p_eval_state bytea,
    p_target_document __CORE_SCHEMA__.bson,
    p_source_document __CORE_SCHEMA__.bson,
    p_is_moderate boolean
   )
RETURNS boolean
LANGUAGE C
  STRICT
AS 'MODULE_PATHNAME', $$command_schema_validation_against_update$$;

/* Overload with bson validator - introduced in 0.114.0 */
/* Uses the same C entry point which handles both bytea and bson based on cluster version */
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL__.schema_validation_against_update(
    validator __CORE_SCHEMA__.bson,
    p_target_document __CORE_SCHEMA__.bson,
    p_source_document __CORE_SCHEMA__.bson,
    p_is_moderate boolean
   )
RETURNS boolean
LANGUAGE C
  STRICT
AS 'MODULE_PATHNAME', $$command_schema_validation_against_update$$;