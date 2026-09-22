#!/bin/bash
#
# documentdb_report_extended_rum.sh
#
# Report the two durable facts about extended RUM once the bundled PostgreSQL
# accepts connections: is documentdb_extended_rum created on the data volume,
# and does this image provide it. Which access method an index gets is decided
# per session by documentdb.alternate_index_handler_name (PGC_USERSET), so it
# is deliberately not read here; the image tests own that default.
#
# Always exits 0: every line is a statement of what was found, never a verdict
# on the server, and nothing here stops the boot.
#
# Usage: documentdb_report_extended_rum.sh <postgresql_port> <owner> <pg_accepting>
#   pg_accepting  "true" when the caller's readiness gate saw the server up;
#                 decides how an unanswered probe is worded.

postgresql_port="$1"
owner="$2"
pg_accepting="${3:-true}"

if ! state="$(psql -p "$postgresql_port" -U "$owner" -d postgres -X -tA -F , \
        -c "SELECT (SELECT count(*) FROM pg_extension WHERE extname = 'documentdb_extended_rum'), (SELECT count(*) FROM pg_available_extensions WHERE name = 'documentdb_extended_rum')" < /dev/null 2>/dev/null)"; then
    state=""
fi

case "$state" in
    1,*)
        echo "documentdb_extended_rum is created on this data volume." ;;
    0,1)
        echo "Warning: documentdb_extended_rum is not created on this data volume, although this image provides it. Indexes on this volume cannot use the extended_rum access method until it is created. If the volume's shared_preload_libraries already lists pg_documentdb_extended_rum, run CREATE EXTENSION documentdb_extended_rum in the postgres database as the data directory owner; otherwise the extension cannot load there, so initialize a fresh data volume with this image." >&2 ;;
    0,0)
        echo "Warning: this image does not provide the documentdb_extended_rum extension, so indexes use the plain rum access method without covered queries (index-only scans). Pull a newer documentdb-local image." >&2 ;;
    *)
        # Silence is an anomaly only if the readiness gate saw the server up.
        if [ "$pg_accepting" = "true" ]; then
            echo "Warning: could not verify the documentdb_extended_rum state although PostgreSQL is accepting connections (probe returned '${state}'); continuing." >&2
        else
            echo "Warning: could not verify the documentdb_extended_rum state; PostgreSQL was not confirmed to be accepting connections yet. Continuing." >&2
        fi ;;
esac
exit 0
