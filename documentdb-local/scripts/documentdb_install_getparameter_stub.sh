#!/bin/bash
#
# documentdb_install_getparameter_stub.sh
#
# getParameter is intentionally unsupported in OSS, but the bundled gateway still
# dispatches it to documentdb_api.get_parameter(...), which has never shipped in
# the OSS extension. Install an emulator-only rejection stub in the bundled
# database (start_oss_server.sh pins documentdb_gateway.database to postgres) so
# clients receive the gateway's normal unsupported-command response instead of
# PostgreSQL 42883. Preserve a real implementation if one is added later; this
# temporary bridge can then be removed with the gateway fix.
#
# Only for the emulator's OWN bundled PostgreSQL: START_POSTGRESQL=false targets a
# caller-managed backend, and the entrypoint excludes it, so this workaround never
# installs its private rejection function in an external PostgreSQL instance.
#
# Usage: documentdb_install_getparameter_stub.sh <postgresql_port>

postgresql_port="$1"

echo "Ensuring unsupported getParameter returns CommandNotSupported (issue #650)..."
if ! psql -p "$postgresql_port" -d postgres -X -v ON_ERROR_STOP=1 <<'GET_PARAMETER_SQL'
DO $install_get_parameter_stub$
BEGIN
    IF to_regprocedure('documentdb_api.get_parameter(boolean,boolean,text[])') IS NULL THEN
        EXECUTE $ddl$
            CREATE FUNCTION documentdb_api.get_parameter(boolean, boolean, text[])
            RETURNS documentdb_core.bson
            LANGUAGE sql
            STABLE
            SET search_path = pg_catalog
            AS $body$
                SELECT documentdb_core.bson_in(
                    '{ "ok": 0.0, "errmsg": "Command ''getParameter'' not supported.", "code": 115, "codeName": "CommandNotSupported" }'::cstring
                )
            $body$
        $ddl$;
        EXECUTE $comment$
            COMMENT ON FUNCTION documentdb_api.get_parameter(boolean, boolean, text[])
            IS 'documentdb-local temporary CommandNotSupported stub for issue #650'
        $comment$;
    END IF;
END;
$install_get_parameter_stub$;
GET_PARAMETER_SQL
then
    echo "Error: could not install the documentdb-local getParameter rejection stub; refusing to start with the known PostgreSQL 42883 failure (issue #650)." >&2
    exit 1
fi
