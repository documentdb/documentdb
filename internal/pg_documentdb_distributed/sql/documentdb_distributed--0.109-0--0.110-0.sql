-- Admin role needs LOGIN privilege to run move collection functions
ALTER ROLE __API_ADMIN_ROLE__ WITH LOGIN;

GRANT SELECT ON TABLE documentdb_api_distributed.documentdb_cluster_data TO documentdb_readwrite_role;
GRANT USAGE ON SCHEMA documentdb_api_distributed TO documentdb_readwrite_role;

GRANT SELECT ON TABLE documentdb_api_distributed.documentdb_cluster_data TO documentdb_api_find_role;
GRANT SELECT ON TABLE documentdb_api_distributed.documentdb_cluster_data TO documentdb_api_insert_role;
GRANT SELECT ON TABLE documentdb_api_distributed.documentdb_cluster_data TO documentdb_api_update_role;
GRANT SELECT ON TABLE documentdb_api_distributed.documentdb_cluster_data TO documentdb_api_remove_role;
GRANT USAGE ON SCHEMA documentdb_api_distributed TO documentdb_api_find_role;
GRANT USAGE ON SCHEMA documentdb_api_distributed TO documentdb_api_insert_role;
GRANT USAGE ON SCHEMA documentdb_api_distributed TO documentdb_api_update_role;
GRANT USAGE ON SCHEMA documentdb_api_distributed TO documentdb_api_remove_role;
