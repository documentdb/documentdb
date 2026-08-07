/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/documentdb_distributed_init.c
 *
 * Initialization of the shared library initialization for distribution for Hleio API.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <miscadmin.h>
#include <utils/guc.h>

#include "documentdb_distributed_init.h"


/* --------------------------------------------------------- */
/* GUCs and default values */
/* --------------------------------------------------------- */

/* SystemConfig */
#define DEFAULT_ENABLE_METADATA_REFERENCE_SYNC true
bool EnableMetadataReferenceTableSync = DEFAULT_ENABLE_METADATA_REFERENCE_SYNC;

/* SystemConfig */
#define DEFAULT_ENABLE_SHARD_REBALANCER false
bool EnableShardRebalancer = DEFAULT_ENABLE_SHARD_REBALANCER;

/* SystemConfig */
#define DEFAULT_CLUSTER_ADMIN_ROLE ""
char *ClusterAdminRole = DEFAULT_CLUSTER_ADMIN_ROLE;

/* FeatureFlag */
/* Added in v114, enabled in v114, remove after v119 */
#define DEFAULT_ENABLE_MOVE_COLLECTION true
bool EnableMoveCollection = DEFAULT_ENABLE_MOVE_COLLECTION;

/* FeatureFlag */
/* Added in v116, Pending stabilization, enable in v118 */
#define DEFAULT_ENABLE_SKIP_UPGRADE_FOR_UNINITIALIZED_CLUSTER false
bool EnableSkipUpgradeForUninitializedCluster =
	DEFAULT_ENABLE_SKIP_UPGRADE_FOR_UNINITIALIZED_CLUSTER;

/* SystemConfig */
#define DEFAULT_ADD_NODE_PORT_TO_NODE_NAME false
bool AddNodePortToNodeName = DEFAULT_ADD_NODE_PORT_TO_NODE_NAME;

/* --------------------------------------------------------- */
/* Top level exports */
/* --------------------------------------------------------- */

/*
 * Initializes core configurations pertaining to documentdb distributed.
 */
void
InitDocumentDBDistributedConfigurations(const char *prefix)
{
	DefineCustomBoolVariable(
		psprintf("%s.enable_metadata_reference_table_sync", prefix),
		gettext_noop(
			"Determines whether or not to enable metadata reference table syncs."),
		NULL, &EnableMetadataReferenceTableSync, DEFAULT_ENABLE_METADATA_REFERENCE_SYNC,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_shard_rebalancer_apis", prefix),
		gettext_noop(
			"Determines whether or not to enable shard rebalancer APIs."),
		NULL, &EnableShardRebalancer, DEFAULT_ENABLE_SHARD_REBALANCER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_move_collection", prefix),
		gettext_noop(
			"Determines whether or not to enable move collection."),
		NULL, &EnableMoveCollection, DEFAULT_ENABLE_MOVE_COLLECTION,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.enable_skip_upgrade_for_uninitialized_cluster", prefix),
		gettext_noop(
			"Determines whether complete_upgrade is skipped when the cluster has "
			"not been initialized yet."),
		NULL, &EnableSkipUpgradeForUninitializedCluster,
		DEFAULT_ENABLE_SKIP_UPGRADE_FOR_UNINITIALIZED_CLUSTER,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomStringVariable(
		psprintf("%s.clusterAdminRole", prefix),
		gettext_noop(
			"The cluster admin role."),
		NULL, &ClusterAdminRole, DEFAULT_CLUSTER_ADMIN_ROLE,
		PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(
		psprintf("%s.add_node_port_to_node_name", prefix),
		gettext_noop(
			"Determines whether the node port is appended as a suffix to the "
			"formatted node name."),
		NULL, &AddNodePortToNodeName, DEFAULT_ADD_NODE_PORT_TO_NODE_NAME,
		PGC_USERSET, 0, NULL, NULL, NULL);
}
