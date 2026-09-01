/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/distribution/collections_schema_repair.c
 *
 * Repairs a collections catalog table whose column layout has drifted away
 * from the local reference table shard.
 *
 * A node that joins a cluster which was initialized at an older extension
 * version keeps the collections table its own schema scripts created, while
 * the reference table shard replicated onto that node carries the column
 * layout the coordinator actually uses. Version-gated cluster setup actions
 * only run inside the (lastUpgradeVersion, installedVersion] window, so once
 * the window has moved past them the drift is never corrected and the two
 * relations disagree on both the column set and the column order.
 *
 * The shard is the authoritative copy, so the repair rebuilds the catalog
 * table from it and repoints the shard metadata at the rebuilt table.
 *-------------------------------------------------------------------------
 */
#include <postgres.h>
#include <fmgr.h>
#include <miscadmin.h>
#include <utils/array.h>
#include <utils/builtins.h>
#include <utils/lsyscache.h>
#include <catalog/namespace.h>

#include "io/bson_core.h"
#include "metadata/metadata_cache.h"
#include "utils/type_cache.h"
#include "utils/query_utils.h"
#include "utils/guc_utils.h"

/* Name of the catalog table that is repaired. */
#define COLLECTIONS_TABLE_NAME "collections"

/* Staging table that the repaired layout is built in. */
#define COLLECTIONS_COPY_TABLE_NAME "collections_copy"

/* Name the drifted table is retained under, for inspection. */
#define COLLECTIONS_ORIG_TABLE_NAME "collections_orig"

PG_FUNCTION_INFO_V1(command_repair_collections_table_schema);
PG_FUNCTION_INFO_V1(command_is_table_schema_consistent);

static int64 GetLocalCollectionsShardId(void);
static pgbson * GetTableSchemaComparison(const char *qualifiedRelationName,
										 bool *shardFound, bool *isConsistent);
static void CreateCollectionsCopyFromShard(int64 shardId);
static void CopyShardTriggersToCollectionsCopy(int64 shardId);
static void SwapCollectionsTables(void);
static void RepointShardMetadataToCollections(int64 shardId);
static List * GetIndexRenameCommands(const char *qualifiedTableName,
									 const char *oldPrefix, const char *newPrefix);
static void SwapCollectionsIndexNames(void);
static void CopyCollectionsOwnerAndGrants(void);
static void TransferExtensionMembership(void);
static List * RunTextArrayQuery(const char *query);
static char * QualifiedCollectionsName(const char *relationName);
static char * ShardRelationName(int64 shardId);
static void EnsureRelationAbsent(const char *relationName);


/*
 * Rebuilds the collections catalog table from the local reference table shard
 * when the two have drifted apart, and repoints the shard metadata at the
 * rebuilt table.
 *
 * Exposed as a procedure so that the surrounding CALL supplies the transaction
 * that makes the rename and catalog updates atomic. The whole repair must run
 * in a single top level transaction; callers must not commit part way through
 * it, or the table would be left renamed with the shard metadata still
 * pointing elsewhere. The repair is local to the node it runs on; distributed
 * DDL propagation is disabled throughout so that a single drifted node can be
 * repaired without touching its peers.
 */
Datum
command_repair_collections_table_schema(PG_FUNCTION_ARGS)
{
	/*
	 * Shards are hidden from catalog lookups for most application names, and
	 * the repair has to address the shard directly. DDL propagation is
	 * disabled so the rebuild stays local to this node. The search path is
	 * pinned so that generated definitions always schema qualify their
	 * relations, regardless of what the caller had configured.
	 */
	int savedGUCLevel = NewGUCNestLevel();
	SetGUCLocally("citus.show_shards_for_app_name_prefixes", "*");
	SetGUCLocally("citus.enable_ddl_propagation", "off");
	SetGUCLocally("search_path", "pg_catalog");

	int64 shardId = GetLocalCollectionsShardId();

	bool shardFound = false;
	bool isConsistent = false;
	GetTableSchemaComparison(QualifiedCollectionsName(COLLECTIONS_TABLE_NAME),
							 &shardFound, &isConsistent);

	/*
	 * Shard metadata reaches a node before the shard itself is replicated onto
	 * it, so a node can advertise a shard it does not yet hold. There is
	 * nothing to rebuild from in that window, and reporting it here is clearer
	 * than failing several steps later on a missing relation.
	 */
	if (!shardFound)
	{
		ereport(ERROR,
				(errmsg("%s.%s shard " INT64_FORMAT " is not present on this node",
						ApiCatalogSchemaName, COLLECTIONS_TABLE_NAME, shardId)));
	}

	if (isConsistent)
	{
		ereport(INFO,
				(errmsg("%s.%s already matches shard " INT64_FORMAT
						", skipping repair",
						ApiCatalogSchemaName, COLLECTIONS_TABLE_NAME, shardId)));
		RollbackGUCChange(savedGUCLevel);
		PG_RETURN_VOID();
	}

	/*
	 * A leftover table from an earlier repair would be silently overwritten by
	 * the rename below, so refuse rather than destroy it.
	 */
	EnsureRelationAbsent(COLLECTIONS_ORIG_TABLE_NAME);
	EnsureRelationAbsent(COLLECTIONS_COPY_TABLE_NAME);

	/*
	 * Each step announces itself before it runs, so that a client watching the
	 * session can see how far a repair got if one of them fails.
	 */
	ereport(INFO, (errmsg("repairing %s.%s from shard " INT64_FORMAT,
						  ApiCatalogSchemaName, COLLECTIONS_TABLE_NAME, shardId)));

	ereport(INFO, (errmsg("step 1/7: building the replacement table from the"
						  " shard layout")));
	CreateCollectionsCopyFromShard(shardId);

	ereport(INFO, (errmsg("step 2/7: recreating the shard's triggers on the"
						  " replacement table")));
	CopyShardTriggersToCollectionsCopy(shardId);

	ereport(INFO, (errmsg("step 3/7: retaining the current table as %s.%s and"
						  " moving the replacement table into its place",
						  ApiCatalogSchemaName, COLLECTIONS_ORIG_TABLE_NAME)));
	SwapCollectionsTables();

	ereport(INFO, (errmsg("step 4/7: repointing the shard metadata at the"
						  " replacement table")));
	RepointShardMetadataToCollections(shardId);

	ereport(INFO, (errmsg("step 5/7: restoring the index names")));
	SwapCollectionsIndexNames();

	ereport(INFO, (errmsg("step 6/7: restoring the owner and grants")));
	CopyCollectionsOwnerAndGrants();

	ereport(INFO, (errmsg("step 7/7: restoring the extension membership")));
	TransferExtensionMembership();

	ereport(INFO,
			(errmsg("repaired %s.%s from shard " INT64_FORMAT
					"; previous table retained as %s.%s",
					ApiCatalogSchemaName, COLLECTIONS_TABLE_NAME, shardId,
					ApiCatalogSchemaName, COLLECTIONS_ORIG_TABLE_NAME)));

	RollbackGUCChange(savedGUCLevel);
	PG_RETURN_VOID();
}


/*
 * Reports whether a table still matches the column layout of the reference
 * table shard this node holds for it.
 *
 * Takes the relation so that the same check serves every reference table the
 * extension creates rather than needing one entry point per table. Returns NULL
 * when this node holds no shard for the relation, which distinguishes "nothing
 * to compare against" from a genuine mismatch. This only reads catalogs; the
 * repair itself is a separate call.
 */
Datum
command_is_table_schema_consistent(PG_FUNCTION_ARGS)
{
	/*
	 * A regclass argument is not validated on input and the oid of a relation
	 * dropped after the caller read it stays castable, so the name lookup below
	 * can be handed an oid with no catalog row. That is reported as unknown
	 * rather than treated as a mismatch.
	 */
	if (PG_ARGISNULL(0))
	{
		PG_RETURN_NULL();
	}

	Oid relationId = PG_GETARG_OID(0);
	char *relationName = OidIsValid(relationId) ? get_rel_name(relationId) : NULL;

	if (relationName == NULL)
	{
		PG_RETURN_NULL();
	}

	char *schemaName = get_namespace_name(get_rel_namespace(relationId));

	if (schemaName == NULL)
	{
		PG_RETURN_NULL();
	}

	/*
	 * Shards are hidden from catalog lookups for most application names, and
	 * the comparison has to resolve the shard by name.
	 */
	int savedGUCLevel = NewGUCNestLevel();
	SetGUCLocally("citus.show_shards_for_app_name_prefixes", "*");
	SetGUCLocally("search_path", "pg_catalog");

	bool shardFound = false;
	bool isConsistent = false;
	pgbson *comparison = GetTableSchemaComparison(
		quote_qualified_identifier(schemaName, relationName), &shardFound,
		&isConsistent);

	RollbackGUCChange(savedGUCLevel);

	if (!shardFound)
	{
		PG_RETURN_NULL();
	}

	PG_RETURN_POINTER(comparison);
}


/*
 * Returns the shard id of the local collections reference table shard.
 */
static int64
GetLocalCollectionsShardId(void)
{
	bool isNull = false;
	bool readOnly = true;

	const char *query = FormatSqlQuery(
		"SELECT shardid FROM pg_dist_shard WHERE logicalrelid = %s::regclass",
		quote_literal_cstr(QualifiedCollectionsName(COLLECTIONS_TABLE_NAME)));

	Datum shardIdDatum = ExtensionExecuteQueryViaSPI(query, readOnly, SPI_OK_SELECT,
													 &isNull);

	if (isNull)
	{
		ereport(ERROR,
				(errmsg("%s.%s has no shard metadata on this node",
						ApiCatalogSchemaName, COLLECTIONS_TABLE_NAME),
				 errdetail_log(
					 "Run this repair on a node that is part of an initialized cluster.")));
	}

	return DatumGetInt64(shardIdDatum);
}


/*
 * Compares the column layout of a table against the reference table shard this
 * node holds for it, setting shardFound to whether such a shard exists and
 * isConsistent to whether the two layouts agree.
 *
 * Returns a document describing the comparison column by column, or NULL when
 * this node holds no shard for the relation. Column order is compared as well
 * as the column set, because a node can end up with the right columns at the
 * wrong positions.
 */
static pgbson *
GetTableSchemaComparison(const char *qualifiedRelationName, bool *shardFound,
						 bool *isConsistent)
{
	/* Positions of the values the comparison query below selects. */
	int shardFoundIndex = 0;
	int consistentIndex = 1;
	int documentIndex = 2;
	int nProjections = 3;

	Datum values[3];
	bool isNull[3];
	bool readOnly = true;

	/*
	 * The shard is located by joining the shard metadata back to the relation,
	 * because a shard table is named after its logical table and lives in the
	 * same schema. Resolving it here rather than from a caller supplied name
	 * keeps this usable for any reference table.
	 *
	 * Each side is reduced to one row per live column, then the two are paired
	 * by column name so that a column present on only one side still appears,
	 * carrying only the position it has on the side that has it. The position
	 * is the ordinal among live columns rather than the raw attribute number,
	 * because a dropped column leaves a permanent gap in the numbering on one
	 * side only and a rebuilt table numbers its columns contiguously. Comparing
	 * raw numbers would report such a pair as drift forever, including
	 * immediately after a successful repair.
	 *
	 * A column matches when its position, type and nullability all agree, so
	 * the aggregated verdict covers the column set, their types and their order
	 * at once. Ordering the columns by shard position reports them in the layout
	 * the shard defines, with columns missing from the shard collected at the
	 * end.
	 *
	 * The document is assembled by the document builders rather than in C, so
	 * the paired rows are turned into the reported columns directly and a
	 * position that is absent on one side is simply left out of that column.
	 *
	 * The format string is kept literal so that the compiler can verify the
	 * argument list, and no percent signs reach the printf style expansion.
	 */
	const char *query = FormatSqlQuery(
		"WITH shard_relation AS ("
		" SELECT shard_class.oid AS shard_oid"
		" FROM pg_dist_shard shard_entry"
		" JOIN pg_catalog.pg_class logical_class"
		"  ON logical_class.oid = shard_entry.logicalrelid"
		" JOIN pg_catalog.pg_class shard_class"
		"  ON shard_class.relnamespace = logical_class.relnamespace"
		"  AND shard_class.relname ="
		"   logical_class.relname || '_' || shard_entry.shardid"
		" WHERE shard_entry.logicalrelid = %s::regclass"
		"), shard_column AS ("
		" SELECT attname,"
		" (row_number() OVER (ORDER BY attnum))::int AS position,"
		" format_type(atttypid, atttypmod) AS type_name, attnotnull"
		" FROM pg_catalog.pg_attribute"
		" WHERE attrelid = (SELECT shard_oid FROM shard_relation)"
		"  AND attnum > 0 AND NOT attisdropped"
		"), table_column AS ("
		" SELECT attname,"
		" (row_number() OVER (ORDER BY attnum))::int AS position,"
		" format_type(atttypid, atttypmod) AS type_name, attnotnull"
		" FROM pg_catalog.pg_attribute"
		" WHERE attrelid = %s::regclass AND attnum > 0 AND NOT attisdropped"
		"), paired_column AS ("
		" SELECT coalesce(shard_column.attname, table_column.attname)::text AS name,"
		" shard_column.position AS \"shardPosition\","
		" table_column.position AS \"tablePosition\","
		" (shard_column.position IS NOT DISTINCT FROM table_column.position"
		"  AND shard_column.type_name IS NOT DISTINCT FROM table_column.type_name"
		"  AND shard_column.attnotnull IS NOT DISTINCT FROM table_column.attnotnull"
		" ) AS matches"
		" FROM shard_column FULL OUTER JOIN table_column"
		"  ON table_column.attname = shard_column.attname"
		"), verdict AS ("
		" SELECT coalesce(bool_and(matches), false) AS consistent FROM paired_column"
		")"
		" SELECT (SELECT count(*) FROM shard_relation) > 0, verdict.consistent,"
		" %s.bson_dollar_merge_documents("
		"  %s.bson_build_document('table'::text, %s::text,"
		"   'consistent'::text, verdict.consistent),"
		"  (SELECT %s.bson_array_agg(%s.row_get_bson(reported_column), 'columns'"
		"    ORDER BY reported_column.\"shardPosition\" NULLS LAST,"
		"     reported_column.\"tablePosition\" NULLS LAST, reported_column.name)"
		"   FROM (SELECT name, \"shardPosition\", \"tablePosition\""
		"    FROM paired_column) reported_column),"
		"  false)"
		" FROM verdict",
		quote_literal_cstr(qualifiedRelationName),
		quote_literal_cstr(qualifiedRelationName),
		quote_identifier(ApiInternalSchemaNameV2),
		quote_identifier(CoreSchemaName),
		quote_literal_cstr(qualifiedRelationName),
		quote_identifier(ApiCatalogSchemaName),
		quote_identifier(CoreSchemaName));

	ExtensionExecuteMultiValueQueryViaSPI(query, readOnly, SPI_OK_SELECT, values,
										  isNull, nProjections);

	*shardFound = !isNull[shardFoundIndex] && DatumGetBool(values[shardFoundIndex]);
	*isConsistent = !isNull[consistentIndex] && DatumGetBool(values[consistentIndex]);

	if (!*shardFound || isNull[documentIndex])
	{
		return NULL;
	}

	return DatumGetPgBson(values[documentIndex]);
}


/*
 * Builds the replacement table from the shard. LIKE copies the columns,
 * defaults, constraints and indexes but never the triggers, which are restored
 * separately.
 */
static void
CreateCollectionsCopyFromShard(int64 shardId)
{
	bool isNull = false;
	bool readOnly = false;

	const char *query = FormatSqlQuery(
		"CREATE TABLE %s (LIKE %s INCLUDING ALL)",
		QualifiedCollectionsName(COLLECTIONS_COPY_TABLE_NAME),
		ShardRelationName(shardId));

	ExtensionExecuteQueryViaSPI(query, readOnly, SPI_OK_UTILITY, &isNull);
}


/*
 * Recreates the shard's triggers on the replacement table.
 *
 * Shard-level trigger names usually carry the shard id as a suffix, so both the
 * trigger name and the target relation in the generated definition are
 * rewritten back to their unsuffixed forms. A name that does not end in the
 * suffix is left alone rather than blindly truncated, and the name is matched
 * as the generated definition spells it so that a name needing quoting is still
 * rewritten.
 */
static void
CopyShardTriggersToCollectionsCopy(int64 shardId)
{
	const char *shardRelationName = ShardRelationName(shardId);
	const char *shardSuffix = psprintf("_" INT64_FORMAT, shardId);
	int suffixLength = (int) strlen(shardSuffix);

	/*
	 * pg_get_triggerdef reproduces the whole CREATE TRIGGER, still naming the
	 * shard as its target, so the inner query redirects it at the staging table
	 * before the outer query strips the shard id from the trigger's own name.
	 * Internal triggers are excluded because the distribution layer maintains
	 * those itself.
	 */
	const char *query = FormatSqlQuery(
		"SELECT array_agg("
		" CASE WHEN length(shard_trigger.tgname) > %d"
		"  AND right(shard_trigger.tgname, %d) = %s"
		" THEN replace(shard_trigger.definition,"
		"  'CREATE TRIGGER ' || quote_ident(shard_trigger.tgname) || ' ',"
		"  'CREATE TRIGGER ' || quote_ident(left(shard_trigger.tgname,"
		"   length(shard_trigger.tgname) - %d)) || ' ')"
		" ELSE shard_trigger.definition END"
		" ORDER BY shard_trigger.tgname)"
		" FROM ("
		" SELECT trigger_entry.tgname,"
		"  replace(pg_get_triggerdef(trigger_entry.oid),"
		"   ' ON ' || %s || ' ', ' ON ' || %s || ' ') AS definition"
		" FROM pg_catalog.pg_trigger trigger_entry"
		" WHERE trigger_entry.tgrelid = %s::regclass"
		" AND NOT trigger_entry.tgisinternal) shard_trigger",
		suffixLength,
		suffixLength,
		quote_literal_cstr(shardSuffix),
		suffixLength,
		quote_literal_cstr(shardRelationName),
		quote_literal_cstr(QualifiedCollectionsName(COLLECTIONS_COPY_TABLE_NAME)),
		quote_literal_cstr(shardRelationName));

	List *triggerDefinitions = RunTextArrayQuery(query);

	ListCell *definitionCell;
	foreach(definitionCell, triggerDefinitions)
	{
		bool isNull = false;
		bool readOnly = false;
		char *triggerDefinition = (char *) lfirst(definitionCell);

		ExtensionExecuteQueryViaSPI(triggerDefinition, readOnly, SPI_OK_UTILITY,
									&isNull);
	}
}


/*
 * Renames the drifted table out of the way and moves the replacement table
 * into its place.
 */
static void
SwapCollectionsTables(void)
{
	bool isNull = false;
	bool readOnly = false;

	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery("ALTER TABLE %s RENAME TO %s",
					   QualifiedCollectionsName(COLLECTIONS_TABLE_NAME),
					   quote_identifier(COLLECTIONS_ORIG_TABLE_NAME)),
		readOnly, SPI_OK_UTILITY, &isNull);

	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery("ALTER TABLE %s RENAME TO %s",
					   QualifiedCollectionsName(COLLECTIONS_COPY_TABLE_NAME),
					   quote_identifier(COLLECTIONS_TABLE_NAME)),
		readOnly, SPI_OK_UTILITY, &isNull);
}


/*
 * Points the shard and partition metadata at the replacement table.
 *
 * The rename leaves both entries referencing the retained table, because a
 * rename does not change the relation oid that the metadata stores.
 */
static void
RepointShardMetadataToCollections(int64 shardId)
{
	bool isNull = false;
	bool readOnly = false;

	const char *collectionsName =
		quote_literal_cstr(QualifiedCollectionsName(COLLECTIONS_TABLE_NAME));
	const char *retainedName =
		quote_literal_cstr(QualifiedCollectionsName(COLLECTIONS_ORIG_TABLE_NAME));

	/*
	 * The shard row is addressed by shard id rather than by relation oid,
	 * because the placement is what identifies it; the partition row has no
	 * such key and is matched on the retained table instead.
	 */
	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery(
			"UPDATE pg_dist_shard SET logicalrelid = %s::regclass"
			" WHERE shardid = " INT64_FORMAT, collectionsName, shardId),
		readOnly, SPI_OK_UPDATE, &isNull);

	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery(
			"UPDATE pg_dist_partition SET logicalrelid = %s::regclass"
			" WHERE logicalrelid = %s::regclass", collectionsName, retainedName),
		readOnly, SPI_OK_UPDATE, &isNull);
}


/*
 * Returns the ALTER INDEX commands that re-prefix every index on the given
 * table from oldPrefix to newPrefix.
 */
static List *
GetIndexRenameCommands(const char *qualifiedTableName, const char *oldPrefix,
					   const char *newPrefix)
{
	/*
	 * Each row rebuilds one command as: ALTER INDEX <oid resolved name> RENAME
	 * TO <newPrefix + the part of the old name after oldPrefix>. The index is
	 * addressed through its oid rather than by name so that the command stays
	 * correct no matter which schema the index lives in, and substr starts one
	 * character past the prefix because SQL string positions are one based.
	 * Only indexes whose leading characters match oldPrefix are considered, so
	 * an index that was never named after the table is left alone.
	 */
	const char *query = FormatSqlQuery(
		"SELECT array_agg("
		" 'ALTER INDEX ' || index_class.oid::regclass::text ||"
		" ' RENAME TO ' || quote_ident(%s || substr(index_class.relname, %d))"
		" ORDER BY index_class.relname)"
		" FROM pg_catalog.pg_index index_entry"
		" JOIN pg_catalog.pg_class index_class"
		" ON index_class.oid = index_entry.indexrelid"
		" WHERE index_entry.indrelid = %s::regclass"
		" AND left(index_class.relname, %d) = %s",
		quote_literal_cstr(newPrefix),
		(int) strlen(oldPrefix) + 1,
		quote_literal_cstr(qualifiedTableName),
		(int) strlen(oldPrefix),
		quote_literal_cstr(oldPrefix));

	return RunTextArrayQuery(query);
}


/*
 * Gives the replacement table's indexes the names the drifted table used.
 *
 * LIKE derives index names from the staging table name, so every index on the
 * replacement table is still named after it. The retained table's indexes are
 * moved aside first to free up the canonical names. Index renames carry the
 * backing constraint name along with them.
 */
static void
SwapCollectionsIndexNames(void)
{
	List *renameCommands = GetIndexRenameCommands(
		QualifiedCollectionsName(COLLECTIONS_ORIG_TABLE_NAME),
		COLLECTIONS_TABLE_NAME "_", COLLECTIONS_ORIG_TABLE_NAME "_");

	renameCommands = list_concat(renameCommands, GetIndexRenameCommands(
									 QualifiedCollectionsName(COLLECTIONS_TABLE_NAME),
									 COLLECTIONS_COPY_TABLE_NAME "_",
									 COLLECTIONS_TABLE_NAME "_"));

	ListCell *renameCell;
	foreach(renameCell, renameCommands)
	{
		bool isNull = false;
		bool readOnly = false;
		char *renameCommand = (char *) lfirst(renameCell);

		ExtensionExecuteQueryViaSPI(renameCommand, readOnly, SPI_OK_UTILITY, &isNull);
	}
}


/*
 * Reapplies the retained table's owner and privileges to the replacement table.
 *
 * LIKE reproduces the column layout, indexes and constraints but never the
 * ownership or the access control list. Without this the replacement table
 * would be reachable only by whoever ran the repair, and every role the
 * extension grants access to would silently lose it.
 */
static void
CopyCollectionsOwnerAndGrants(void)
{
	const char *targetName = quote_literal_cstr(
		QualifiedCollectionsName(COLLECTIONS_TABLE_NAME));
	const char *sourceName = quote_literal_cstr(
		QualifiedCollectionsName(COLLECTIONS_ORIG_TABLE_NAME));

	/*
	 * The statements are built from the retained table's catalog entries and
	 * applied to the replacement table. aclexplode turns the packed access
	 * control list into one row per grantee and privilege, a grantee of zero
	 * being the pseudo role PUBLIC. The ordering column keeps the ALTER TABLE
	 * ahead of the grants because changing the owner rewrites the owner's
	 * implicit entries, so replaying the grants first would lose them again.
	 */
	const char *query = FormatSqlQuery(
		"SELECT array_agg(statement ORDER BY sortOrder, statement)"
		" FROM ("
		" SELECT 0 AS sortOrder, 'ALTER TABLE ' || %s || ' OWNER TO ' ||"
		" quote_ident(pg_catalog.pg_get_userbyid(relation.relowner)) AS statement"
		" FROM pg_catalog.pg_class relation WHERE relation.oid = %s::regclass"
		" UNION ALL"
		" SELECT 1, 'GRANT ' || acl.privilege_type || ' ON TABLE ' || %s || ' TO ' ||"
		" CASE WHEN acl.grantee = 0 THEN 'PUBLIC'"
		" ELSE quote_ident(pg_catalog.pg_get_userbyid(acl.grantee)) END ||"
		" CASE WHEN acl.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END"
		" FROM pg_catalog.pg_class relation,"
		" pg_catalog.aclexplode(relation.relacl) acl"
		" WHERE relation.oid = %s::regclass"
		") statements",
		targetName, sourceName, targetName, sourceName);

	List *grantCommands = RunTextArrayQuery(query);

	ListCell *grantCell;
	foreach(grantCell, grantCommands)
	{
		bool isNull = false;
		bool readOnly = false;
		char *grantCommand = (char *) lfirst(grantCell);

		ExtensionExecuteQueryViaSPI(grantCommand, readOnly, SPI_OK_UTILITY, &isNull);
	}
}


/*
 * Moves the extension membership from the retained table onto the replacement
 * table.
 *
 * The drifted table was created by the extension, so it carries an extension
 * dependency that the replacement table does not. Leaving it behind would make
 * dropping the extension, and dumping it, follow the retained table instead of
 * the live one.
 */
static void
TransferExtensionMembership(void)
{
	bool isNull = false;
	bool readOnly = false;

	/*
	 * An extension member is an entry in pg_depend whose dependency type is 'e'
	 * and whose referenced object is the extension, so the join reads back the
	 * name of the extension that owns the retained table. A table with no such
	 * entry yields no row, and is then left alone rather than being adopted.
	 */
	Datum extensionNameDatum = ExtensionExecuteQueryViaSPI(
		FormatSqlQuery(
			"SELECT extension.extname::text FROM pg_catalog.pg_depend dependency"
			" JOIN pg_catalog.pg_extension extension ON extension.oid = dependency.refobjid"
			" WHERE dependency.classid = 'pg_catalog.pg_class'::regclass"
			" AND dependency.refclassid = 'pg_catalog.pg_extension'::regclass"
			" AND dependency.deptype = 'e'"
			" AND dependency.objid = %s::regclass",
			quote_literal_cstr(QualifiedCollectionsName(COLLECTIONS_ORIG_TABLE_NAME))),
		readOnly, SPI_OK_SELECT, &isNull);

	if (isNull)
	{
		return;
	}

	const char *extensionName = quote_identifier(TextDatumGetCString(
													 extensionNameDatum));
	bool executeReadOnly = false;

	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery("ALTER EXTENSION %s DROP TABLE %s", extensionName,
					   QualifiedCollectionsName(COLLECTIONS_ORIG_TABLE_NAME)),
		executeReadOnly, SPI_OK_UTILITY, &isNull);

	ExtensionExecuteQueryViaSPI(
		FormatSqlQuery("ALTER EXTENSION %s ADD TABLE %s", extensionName,
					   QualifiedCollectionsName(COLLECTIONS_TABLE_NAME)),
		executeReadOnly, SPI_OK_UTILITY, &isNull);
}


/*
 * Runs a query returning a single text[] and returns its elements as a list of
 * strings. An empty result yields an empty list.
 */
static List *
RunTextArrayQuery(const char *query)
{
	bool isNull = false;

	/*
	 * These queries inspect relations that earlier steps created or renamed in
	 * this same transaction, so they must run with a fresh snapshot rather than
	 * the caller's.
	 */
	bool readOnly = false;

	Datum resultDatum = ExtensionExecuteQueryViaSPI(query, readOnly, SPI_OK_SELECT,
													&isNull);

	if (isNull)
	{
		return NIL;
	}

	ArrayType *resultArray = DatumGetArrayTypeP(resultDatum);

	Datum *elements = NULL;
	bool *elementNulls = NULL;
	int elementCount = 0;
	deconstruct_array(resultArray, TEXTOID, -1, false, TYPALIGN_INT,
					  &elements, &elementNulls, &elementCount);

	List *results = NIL;
	for (int elementIndex = 0; elementIndex < elementCount; elementIndex++)
	{
		if (elementNulls[elementIndex])
		{
			continue;
		}

		results = lappend(results, TextDatumGetCString(elements[elementIndex]));
	}

	return results;
}


/*
 * Returns the schema qualified, quoted name of a relation in the catalog
 * schema.
 */
static char *
QualifiedCollectionsName(const char *relationName)
{
	return quote_qualified_identifier(ApiCatalogSchemaName, relationName);
}


/*
 * Returns the schema qualified, quoted name of the collections shard.
 */
static char *
ShardRelationName(int64 shardId)
{
	return QualifiedCollectionsName(
		psprintf("%s_" INT64_FORMAT, COLLECTIONS_TABLE_NAME, shardId));
}


/*
 * Errors if a relation the repair intends to create already exists.
 */
static void
EnsureRelationAbsent(const char *relationName)
{
	Oid namespaceOid = get_namespace_oid(ApiCatalogSchemaName, false);

	if (OidIsValid(get_relname_relid(relationName, namespaceOid)))
	{
		ereport(ERROR,
				(errmsg("relation %s.%s already exists",
						ApiCatalogSchemaName, relationName),
				 errdetail_log("Drop it once the previous repair has been verified.")));
	}
}
