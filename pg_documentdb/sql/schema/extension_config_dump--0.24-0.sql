SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.collections')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.collection_indexes')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.collections_collection_id_seq')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.collection_indexes_index_id_seq')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump((__SINGLE_QUOTED_STRING__(__API_CATALOG_SCHEMA__) || '.' || __SINGLE_QUOTED_STRING__(__EXTENSION_OBJECT__(_index_queue)))::regclass, '');
