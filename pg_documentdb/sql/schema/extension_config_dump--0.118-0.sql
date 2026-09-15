#include "extension_config_dump--0.24-0.sql"

SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.roles')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_DATA_SCHEMA__) || '.retryable_writes')::regclass, '');
