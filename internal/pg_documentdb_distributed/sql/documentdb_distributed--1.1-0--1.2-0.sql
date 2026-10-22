/*
 * A table created through the collection owner role stays owned by it, and the
 * tooling that relocates a shard connects as the owner of the table it is
 * moving, so an owner that cannot connect cannot be relocated. No password is
 * set for the role, so this is what that tooling needs and not a way in.
 */
ALTER ROLE documentdb_rbac_api_collection_owner_role LOGIN;

/*
 * Distributed index creation connects to worker nodes as the security-definer
 * identity. No password is set for the role.
 */
ALTER ROLE documentdb_rbac_api_index_create_role LOGIN;

/*
 * Per-node collection commands execute against the collection relation as its
 * owner and call functions in this schema.
 */
GRANT USAGE ON SCHEMA __API_SCHEMA_INTERNAL_V2__
	TO documentdb_rbac_api_collection_owner_role;
