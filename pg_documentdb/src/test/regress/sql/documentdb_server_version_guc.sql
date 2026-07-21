SHOW documentdb.server_version;
SHOW documentdb.max_wire_version;

SET documentdb.server_version TO '8.0';
SHOW documentdb.server_version;
SHOW documentdb.max_wire_version;

SET documentdb.server_version TO '8.0.4';
SHOW documentdb.server_version;

SET documentdb.max_wire_version TO 25;
SHOW documentdb.max_wire_version;

SET documentdb.server_version TO '4.2';
SHOW documentdb.server_version;

RESET documentdb.server_version;
RESET documentdb.max_wire_version;
SHOW documentdb.server_version;
SHOW documentdb.max_wire_version;

-- Invalid server_version / out-of-range max_wire_version are rejected.
SET documentdb.server_version TO '';
SET documentdb.server_version TO 'not-a-version';
SET documentdb.server_version TO '8';
SET documentdb.server_version TO '8.0.4.1.2';
SET documentdb.max_wire_version TO -1;
SET documentdb.max_wire_version TO 0;
