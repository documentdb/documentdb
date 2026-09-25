/*
 * A table created through the collection owner role stays owned by it, and the
 * tooling that relocates a shard connects as the owner of the table it is
 * moving, so an owner that cannot connect cannot be relocated. No password is
 * set for the role, so this is what that tooling needs and not a way in.
 */
ALTER ROLE documentdb_rbac_api_collection_owner_role LOGIN;
