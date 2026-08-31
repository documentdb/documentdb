#include "udfs/query/bson_orderby_meta--1.0-0.sql"
#include "udfs/stats/documentdb_stat_bgworker--1.0-0.sql"
#include "udfs/stats/documentdb_stat_reset_shared--1.0-0.sql"
#include "udfs/schema_mgmt/compact--1.0-0.sql"
#include "udfs/aggregation/bson_aggregation_update--1.0-0.sql"
#include "udfs/aggregation/bson_aggregation_delete--1.0-0.sql"
#include "udfs/aggregation/bson_aggregation_find_and_modify--1.0-0.sql"

SELECT documentdb_api_internal.apply_extension_data_table_upgrade(1, 0, 0);
