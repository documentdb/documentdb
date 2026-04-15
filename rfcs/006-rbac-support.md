---
rfc: 006
title: "RBAC: Supporting DocumentDB's RBAC model on PG"
status: Draft
owner: "@nitinahuja89"
issue: "https://github.com/documentdb/documentdb/issues/TBD"
---

# RFC-006: RBAC: Supporting DocumentDB's RBAC model on PG

**Note**: Throughout this document, "PG" refers to PostgreSQL.

## Problem

DocumentDB aims to provide MongoDB-compatible RBAC (Role-Based Access Control) functionality while running on PG as the underlying engine. However, MongoDB's privilege system includes specific privileges that don't have direct equivalents in PG's native permission model. This creates a compatibility gap that needs to be addressed to provide compatibility with MongoDB RBAC functionality to DocumentDB users.

Additionally, MongoDB's database-scoped role grant model (`grantRolesToUser` with `db` parameter) fundamentally differs from PostgreSQL's cluster-wide role membership, creating a significant architectural challenge.

**MongoDB privileges not natively available in PG:**

MongoDB's privilege system consists of 110+ granular privilege actions organized across multiple categories (Query/Write, Database Management, Deployment Management, Change Streams, Replication, Sharding, Server Administration, Sessions, Diagnostics, and Internal actions). See [Appendix A](#appendix-a-complete-list-of-mongodb-privileges) for the complete categorized list.

**Key categories of missing privileges:**

Given that DocumentDB maps MongoDB database maps to PG schema and MongoDB collection maps to PG table, many basic CRUD and DDL operations do map to PG privileges (`find`→SELECT, `insert`→INSERT, `update`→UPDATE, `remove`→DELETE, `createCollection`→CREATE, `dropCollection`→DROP). However, the following categories of MongoDB privileges lack direct PG equivalents:

1. **MongoDB-Specific Features** - `changeStream`, `bypassDocumentValidation`, `collMod`, `convertToCapped`, `killCursors`, `killAnyCursor`, etc.
   - Change streams, document validation bypass, and capped collections are MongoDB-specific concepts
   - Cursor management (`killCursors`, `killAnyCursor`) - MongoDB cursors are server-side stateful iterators while PG cursors are session-local transaction objects. `killCursors` only partially maps because PG users can always CLOSE their own cursors without privileges. `killAnyCursor` has no equivalent as PG cannot kill other users' cursors due to session isolation.
   - While PG has ALTER TABLE, it doesn't cover all MongoDB `collMod` options

2. **User and Role Management** - `createUser`, `createRole`, `grantRole`, `revokeRole`, `viewUser`, `viewRole`, etc.
   - **Fundamental architectural difference**: In MongoDB, users and roles are stored in specific databases (e.g., user "alice" created in database "mydb" is separate from user "alice" in database "admin"). Users authenticate as `username@database`.
   - PG has these commands but all roles are cluster-wide (stored in `pg_authid` catalog). There's no concept of database-specific users - a role exists across the entire cluster.
   - The `createUser` privilege in MongoDB is database-scoped - having this privilege on database "mydb" allows creating users in that database only
   - **Potential simplification**: If DocumentDB restricts user/role creation to only the `admin` database (unlike MongoDB), this would make users cluster-wide like PG, enabling better mapping:
     - `createUser` could potentially map to PG's `CREATEROLE` privilege
     - `createRole` could also map to `CREATEROLE` 
     - **However, differences remain**: MongoDB has separate privileges for users vs roles, `grantRole`/`revokeRole` work differently than PG's GRANT (see [MongoDB's database-scoped role grants vs PG's cluster-wide role membership](#mongodbs-database-scoped-role-grants-vs-pgs-cluster-wide-role-membership) in the Problem section), and `viewUser`/`viewRole` lack direct PG equivalents
   - Different privilege inheritance and role hierarchy semantics

3. **Diagnostic, Monitoring, and Session Management** - `inprog`, `killop`, `serverStatus`, `collStats`, `dbStats`, `top`, `listSessions`, `killAnySession`, `impersonate`, etc.
   - Many diagnostic and session management commands could partially map to PG system catalog queries and functions:
     - `collStats` → SELECT on `pg_stat_user_tables`, `pg_class`, `pg_table_size()` functions
     - `dbStats` → SELECT on `pg_database`, `pg_stat_database`, `pg_database_size()` functions  
     - `listDatabases` → SELECT on `pg_database` catalog
     - `listCollections` → SELECT on `pg_tables` or `pg_class`
     - `listIndexes` → SELECT on `pg_indexes` or `pg_stat_user_indexes`
     - `serverStatus` → SELECT on various `pg_stat_*` views
     - `inprog` → SELECT on `pg_stat_activity` view
     - `killop` → EXECUTE on `pg_terminate_backend()` and `pg_cancel_backend()` functions
     - `top` → SELECT on `pg_stat_statements` extension tables, `pg_stat_activity` view
     - `listSessions` → SELECT on `pg_stat_activity` view (with appropriate filters)
     - `killAnySession` → EXECUTE on `pg_terminate_backend()` function
     - `impersonate` → PG has `SET ROLE` and `SET SESSION AUTHORIZATION`, but semantics differ (SET ROLE switches to a role you're a member of; SET SESSION AUTHORIZATION requires superuser; MongoDB's impersonate allows acting as another user with different authorization semantics)
   - However, significant RBAC differences remain:
     - PG lacks fine-grained, privilege-level control over statistics visibility (e.g., can't restrict viewing stats for only specific databases)
     - MongoDB's privilege model is more granular (e.g., separate privileges for viewing operations vs killing operations, viewing own operations vs all operations, viewing sessions vs killing sessions vs impersonating users)
     - PG's SELECT privilege on `pg_stat_activity` is all-or-nothing - you either see all sessions or none (can't restrict to specific databases)
     - MongoDB privileges like `killop` allow killing own operations by default, but `killop` as a granted privilege allows killing any operation - PG doesn't have this nuanced distinction

4. **Authentication and Security** - `changePassword`, `changeOwnPassword`, `changeCustomData`, `changeOwnCustomData`, `setAuthenticationRestriction`, etc.
   - Password management privileges - While PG has `ALTER ROLE` for password changes, MongoDB has separate privileges for changing any user's password vs only your own password
   - Custom user data management - MongoDB allows storing arbitrary custom data with users (controlled by `changeCustomData`/`changeOwnCustomData` privileges); PG doesn't have this concept
   - `setAuthenticationRestriction` - MongoDB can restrict authentication by IP address or time - PG handles this through `pg_hba.conf` and connection parameters, not RBAC privileges

5. **Internal and System-Level** - `anyAction`, `internal`, `applyOps`, etc.
   - `anyAction` - Superuser-like privilege allowing any action - While PG has superuser roles, MongoDB's `anyAction` is a grantable privilege that can be scoped to specific resources
   - `internal` - System-level internal actions - No PG equivalent as a privilege
   - `applyOps` - Apply oplog operations directly - Related to MongoDB's replication internals, no PG equivalent
   - These are special-purpose privileges for system administration and internal operations

6. **Administrative Actions** - `setParameter`, `shutdown`, `logRotate`, `compact`, `fsync`, etc.
   - Different server administration commands and configuration mechanisms
   - MongoDB's runtime configuration vs PG's configuration file + SIGHUP model

7. **Sharding and Replication** - `enableSharding`, `addShard`, `moveChunk`, `replSetConfigure`, `replSetGetStatus`, etc.
   - **Sharding privileges** (`enableSharding`, `addShard`, `moveChunk`, etc.) - PG has no native sharding equivalent. PG is a single-node database (though extensions like Citus add sharding capabilities with their own privilege models)
   - **Replication privileges** (`replSetConfigure`, `replSetGetStatus`, etc.) - MongoDB's replica set privileges don't map to PG's replication privileges. PG uses different replication mechanisms (streaming, logical) with different privilege models (e.g., `REPLICATION` role attribute)

8. **Performance and Profiling** - `enableProfiler`, `planCacheRead`, `planCacheWrite`, `planCacheIndexFilter`, `querySettings`, `cpuProfiler`, etc.
   - MongoDB has a built-in profiling system (`enableProfiler`) to track slow queries and operations - PG has logging and statistics extensions but no equivalent profiling privilege model
   - Query optimization privileges (`planCacheRead`, `planCacheWrite`, `planCacheIndexFilter`, `querySettings`) control access to query plan caching and optimization features - PG's query planner is not access-controlled at this granularity
   - `cpuProfiler` privilege for performance analysis - PG has different performance monitoring tools (pg_stat_statements, perf, etc.) without privilege-level access control
   - These features are critical for database performance tuning but represent distinctly different models between MongoDB and PG

**MongoDB's database-scoped role grants vs PG's cluster-wide role membership:**

MongoDB and PG have fundamentally different approaches to granting roles and privileges. **Even if DocumentDB restricts user/role creation to only the `admin` database (making users cluster-wide like PG), the fundamental differences in how role grants work would still remain.** This is because where users are created (which database stores them) is separate from the database scope of role grants (which databases a role applies to when granted to a user).

*MongoDB's approach:*
- `grantRole`/`revokeRole` are dedicated commands specifically for role membership management
- Syntax: `db.grantRolesToUser("username", [{role: "roleName", db: "targetDatabase"}])`
- Each role grant includes a `db` parameter specifying which database that role applies to
- You can grant the same role to a user multiple times, each with a different `db` parameter
- Example: `grantRolesToUser("alice", [{role: "readWrite", db: "sales"}, {role: "read", db: "marketing"}])` - alice has readWrite on sales and read on marketing

*PG's approach:*
- `GRANT` serves two purposes: granting role membership (cluster-wide) and granting object privileges (can be scoped)
- Role membership is cluster-wide: `GRANT readwrite_role TO alice` means alice has the role across ALL databases
- To restrict by database, you grant individual permissions on objects within that database, not role membership

*Key semantic differences:*
- **Scope of role grants**: MongoDB role grants are per-database (you specify the database when granting); PG role membership is cluster-wide (a role granted to a user applies across all databases)
- **Granularity**: MongoDB can grant the same role to a user multiple times with different database contexts; PG grants a role once, globally
- **Privilege binding**: In MongoDB, privileges are bound to roles with resource specifications; when you grant a role, you specify which database those privileges apply to. In PG, privileges are separately granted to objects after role membership is established

These architectural differences make it challenging to map MongoDB's `grantRole`/`revokeRole` directly to PG's GRANT/REVOKE system without custom metadata to track the database-scoped nature of MongoDB role grants.

**Current State of DocumentDB RBAC:**

DocumentDB currently implements a limited subset of MongoDB RBAC with predefined roles:
- `documentdb_admin_role` - Maps to `clusterAdmin` + `readWriteAnyDatabase`
- `documentdb_readonly_role` - Maps to `readAnyDatabase`
- `documentdb_readwrite_role` - Maps to `readWriteAnyDatabase`
- `documentdb_user_admin_role` - Maps to `userAdminAnyDatabase`
- `documentdb_root_role` - Maps to `root`

These roles are implemented as PG roles with standard PG permissions (SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, etc.), which do not provide the granular, action-specific control that MongoDB's privilege system offers.

**Note**: PG natively supports similar concepts (e.g., SELECT corresponds roughly to `find`, INSERT to `insert`, etc.), but lacks the granularity of MongoDB-specific actions listed above. Custom implementation is required to bridge this gap.

**Who is impacted:**

- **Security-conscious users**: Organizations that require fine-grained access control cannot implement their security policies without support for MongoDB's granular privilege types
- **Multi-tenant applications**: Applications that need to isolate privileges between different tenants or user groups
- **DocumentDB contributors**: Contributors implementing new features need a clear framework to add support for MongoDB-compatible privileges

**Current consequences:**

- **Limited RBAC functionality**: DocumentDB does not fully support MongoDB's role-based access control model. Users are restricted to the predefined DocumentDB roles and cannot create custom roles with fine-grained privileges
- **Security gaps**: Inability to enforce fine-grained permissions that MongoDB supports
- **Feature parity issues**: New MongoDB features that rely on specific privileges would not have the right authorization control

**Current workarounds:**

- DocumentDB would require internal mapping to broader PG permissions that don't match MongoDB's granularity
- DocumentDB will offer features that require fine grained privilege checks without authorization control
- Users will need to implement application-level access control instead of database-level RBAC
- Users must work within the limited set of predefined DocumentDB roles

**Success criteria:**

- The architecture provides a way for DocumentDB to support all standard MongoDB privileges, including those not natively available in PostgreSQL
  - Users can create roles with MongoDB-compatible privileges using standard MongoDB commands (e.g., `createRole`, `grantPrivilege`)
  - Privilege enforcement is consistent with MongoDB behavior
- Performance overhead of privilege checking is minimal and acceptable for production use
- Provides an easy mechanism for contributors to add support for new privileges when implementing features that require corresponding privilege checks

---

## Detailed Design

Implementing MongoDB-compatible RBAC on PG requires making architectural decisions across two primary design dimensions: **how to store privilege information** and **where to enforce privilege checks**. This section explores the available options for each dimension.

---

### Design Dimension 1: Privilege Storage Mechanism

**Question**: How do we store and represent DocumentDB privileges in PG?

#### Option A: Normalized Metadata Tables

**Description**: Create dedicated PG tables with a normalized relational schema to store all privilege information, designed specifically for DocumentDB's privilege model.

**Schema Example**:
- `privileges` - Catalog of all DocumentDB privilege actions with metadata for each privilege:
  - Privilege ID (primary key)
  - Privilege name/identifier (e.g., "find", "insert", "createCollection")
  - Description of what the privilege allows
  - Category/grouping (e.g., "Query and Write Actions", "Database Management")
  - Additional metadata (version added, deprecation status, etc.)
- `roles` - Role definitions with one row per role:
  - Role ID (primary key)
  - Role name (e.g., "readWrite", "dbAdmin", "myCustomRole")
  - Description of what the role is for
  - Is built-in flag (true for predefined DocumentDB roles, false for user-created custom roles)
  - Additional metadata (created timestamp, etc.)
- `role_privileges` - Many-to-many mapping with one row per role-privilege-resource combination for ALL roles (both built-in and custom):
  - Which role (role_id)
  - Which privilege (privilege_id)
  - Which resource (resource_id)
  - Grant options and inheritance rules
  - Example: Built-in role "readWrite" would have separate rows for "find", "insert", "update", "remove" privileges
  - Custom roles created by users specify their resources when the role is created, and are stored the same way
  - MongoDB syntax: `db.createRole({role: "myRole", privileges: [{resource: {db: "sales", collection: "orders"}, actions: ["find", "insert"]}]})`
- `user_roles` - User-to-role assignments with one row per user-role-database combination:
  - Which user (user_id)
  - Which role (role_id)
  - On which database the role is granted (database scope)
  - **How resources and grants interact**: The `db` parameter in MongoDB's `grantRolesToUser` interacts with the resources defined in the role through database substitution:
    * **Empty string ("") in role resource = placeholder for grant-time database**
      - Role defines: `resource: {db: "", collection: "orders"}` (any database)
      - Grant: `grantRolesToUser("alice", [{role: "myRole", db: "sales"}])`
      - Effective privilege: alice can access `sales.orders`
      - The grant-time database "sales" fills the empty string placeholder
    * **Specific database in role resource = that database only**
      - Role defines: `resource: {db: "sales", collection: "orders"}` (specific database)
      - Grant: `grantRolesToUser("alice", [{role: "myRole", db: "marketing"}])`
      - Effective privilege: alice can ONLY access `sales.orders` (not marketing!)
      - The role's resource specification takes precedence; grant database just records the membership context
    * **Built-in roles use empty string patterns**
      - Built-in "readWrite" defines: `resource: {db: "", collection: ""}` (any database, any collection)
      - Grant: `grantRolesToUser("alice", [{role: "readWrite", db: "sales"}])`
      - Effective privilege: alice has read/write on all collections in "sales" database
  - At privilege check time, the system evaluates: role definition (which privileges on which resources from `role_privileges`) + role grant context (which database from `user_roles`) + database substitution logic
- `resources` - Resource specifications with one row per unique resource:
  - Resource ID (primary key)
  - Resource type (e.g., "cluster", "any_database", "specific_database", "any_collection", "specific_collection")
  - Database name (null for cluster-wide, empty string "" for any database, specific name like "sales")
  - Collection name (null for database-level, empty string "" for any collection, specific name like "orders")
  - Examples of resources used in role definitions:
    * Cluster-wide: `{type: "cluster", db: null, collection: null}` - for privileges like "shutdown"
    * Any database: `{type: "any_database", db: "", collection: null}` - for cross-database privileges
    * Specific database: `{type: "specific_database", db: "sales", collection: null}` - database-level privileges
    * Any collection in any database: `{type: "any_collection", db: "", collection: ""}` - collection privileges across all databases
    * Specific collection: `{type: "specific_collection", db: "sales", collection: "orders"}` - privileges on a specific collection
  - **Note**: When creating a role, you specify these resources explicitly. They can be specific (db: "sales") or use patterns (db: "" means any database)
  - This table is separate to avoid duplication when multiple role-privilege combinations reference the same resource specification
  - **Implementation note**: When creating a role with privileges:
    1. For each privilege, check if the resource specification already exists in the `resources` table
    2. If found, reuse the existing `resource_id`
    3. If not found, insert a new row into `resources` and get the new `resource_id`
    4. Insert into `role_privileges` using the `resource_id`
  - This lookup-or-insert pattern is standard database normalization practice to maintain data consistency and avoid resource duplication

**How it works**:
- All privilege data stored in custom tables
- Query these tables to determine user privileges
- Complete flexibility in data model design
- Can support database-scoped and collection-scoped privileges

**Pros**:
- Full control over privilege granularity and semantics
- Easy to extend with new privilege types
- Can implement DocumentDB's privilege model with flexibility to deviate from MongoDB where appropriate
- Supports complex privilege inheritance
- Auditable - all privilege information in queryable tables
- Clear separation from PG's native permission system

**Cons**:
- Performance overhead of additional table lookups
- Requires implementing privilege inheritance logic
- Need comprehensive caching strategy
- Doesn't leverage any existing PG functionality
- More code to write and maintain

**Storage vs Query Tradeoff**:
- **Storage is harder**: MongoDB commands (like `createRole`) provide privileges as nested documents/arrays. Option A requires decomposing this structure into multiple normalized tables:
  1. Parse the MongoDB command structure
  2. Lookup/insert role in `roles` table
  3. For each privilege: lookup `privilege_id`, lookup/insert `resource_id`, insert into `role_privileges`
  4. More complex code to transform MongoDB's document model into relational tables
- **Privilege checks require SQL JOINs across multiple tables**: While querying with SQL JOINs is more straightforward than navigating a role hierarchy in document structures, performing these JOINs on every privilege check would still be expensive:
  - Must JOIN across multiple tables: `user_roles` → `role_privileges` → `privileges` → `resources`
  - Must resolve role hierarchy (roles inheriting from other roles) through recursive queries
  - Database indexes help but don't eliminate the JOIN cost on every operation
  - Caching mitigates performance concerns: Since these are custom metadata tables (not PG catalog tables), they cannot leverage PostgreSQL's native catalog cache. Instead, implement a custom cache that:
    * Loads when cache is initialized/invalidated
    * Resolves the full role hierarchy for each user once during cache load
    * Stores a flattened representation mapping (user, resource, action) → allowed/denied
    * Makes runtime privilege checks simple cache lookups rather than expensive multi-table JOINs
    * Can be stored in Gateway process memory (Rust HashMap) or Extension-level (PG shared memory/per-backend cache)
    * See [Cache Invalidation Strategy for Reader Nodes](#cache-invalidation-strategy-for-reader-nodes) section for details on cache invalidation in replicated setups

#### Option B: pgbson Document Metadata

**Description**: Store privilege definitions as `pgbson` documents in metadata tables, providing a flexible document-oriented approach that leverages DocumentDB's existing BSON infrastructure. Unlike Option A's multiple normalized tables, this uses fewer tables with `pgbson` columns to store complex nested privilege data.

**Schema Example**:
- `roles` table storing complete role documents as pgbson:
  - `document` pgbson column containing the entire role document
  - The `_id` field within the document serves as the unique identifier
  - Example for custom role: 
    ```json
    {
      "_id": ObjectId("507f1f77bcf86cd799439011"),
      "role": "myCustomRole",
      "description": "Custom role for sales team",
      "is_builtin": false,
      "privileges": [
        {
          "resource": {"db": "sales", "collection": "orders"},
          "actions": ["find", "insert"]
        }
      ],
      "roles": []
    }
    ```
  - Example for built-in role using placeholders: 
    ```json
    {
      "_id": ObjectId("507f191e810c19729de860ea"),
      "role": "readWrite",
      "is_builtin": true,
      "privileges": [
        {
          "resource": {"db": "", "collection": ""},
          "actions": ["find", "insert", "update", "remove"]
        }
      ],
      "roles": []
    }
    ```
  - Resources are specified when the role is created (as in MongoDB's `createRole` command)
  - Queries use pgbson operators to search within the document (e.g., find role where `document->>'role' = 'readWrite'`)
- `user_roles` table storing complete user role grant documents as pgbson:
  - `document` pgbson column containing the entire user grants document
  - The `_id` field within the document serves as the unique identifier
  - Example pgbson document:
    ```json
    {
      "_id": ObjectId("507f191e810c19729de860eb"),
      "user": "alice",
      "roles": [
        {"role": "read", "db": "marketing"},
        {"role": "myCustomRole", "db": "sales"}
      ]
    }
    ```
  - Queries use pgbson operators to search within the document (e.g., find user where `document->>'user' = 'alice'`)
  - The `db` in each grant interacts with the role's resource definitions through database substitution (same logic as Option A):
    * Empty string ("") in role's resource.db gets filled by the grant-time database
    * Specific database in role's resource.db takes precedence over grant-time database

**How it works**:
- Privilege data stored as pgbson documents
- Use DocumentDB's existing pgbson query operators for querying
- Schema can evolve without table alterations

**Pros**:
- Extremely flexible - easy to add new privilege fields
- No schema migrations needed for new privilege types
- Can store complex nested structures
- Perfect match for DocumentDB's document-oriented privilege model
- Leverages DocumentDB's existing pgbson infrastructure and query operators
- Developers already familiar with pgbson querying patterns in the codebase
- Supports BSON-specific types (ObjectId, etc.)

**Cons**:
- Less type safety - validation must be done in application code
- Harder to enforce referential integrity compared to normalized tables: PostgreSQL cannot automatically validate that role references in user documents point to existing roles. In normalized tables, foreign key constraints prevent orphaned references (e.g., deleting a role that users still reference). With pgbson documents, application code must manually validate references and prevent deletion of roles still in use or remove references from all places where it was used.
- May be harder to audit and report on privileges using standard SQL tools
- Role hierarchy navigation complexity: Determining if a user has a specific privilege requires navigating the role hierarchy (roles can inherit from other roles via the `roles` field). This involves:
  1. Looking up the user's role grants from `user_roles`
  2. For each role, fetching the role document from `roles`
  3. Recursively resolving inherited roles (checking the `roles` field in each role document)
  4. Collecting all privileges from the entire role hierarchy
  - Mitigation: This can be addressed through caching. When the cache is loaded/reloaded, navigate the role hierarchy once and store a flattened representation of all privileges a user has on each resource. Privilege checks then become simple cache lookups rather than recursive hierarchy traversals.

**Storage vs Query Tradeoff**:
- **Storage is easier**: MongoDB commands provide privileges as nested documents, which can be stored directly in pgbson columns with minimal transformation. Simply take the incoming document structure and store it - no need to decompose into multiple tables or manage foreign key relationships.
- **Privilege checks require role hierarchy navigation**: While DocumentDB already has pgbson query operators for querying privilege metadata, determining if a user has a specific privilege requires navigating the role hierarchy (recursively resolving inherited roles via the `roles` field). This makes privilege checks potentially expensive without optimization.
  - Caching mitigates performance concerns: When the cache is loaded/reloaded, navigate the role hierarchy once and store a flattened representation of all privileges a user has on each resource. Privilege checks then become simple cache lookups rather than recursive hierarchy traversals. Cache can be stored in Gateway process memory (Rust HashMap) or Extension-level (PG shared memory/per-backend cache).
    * See [Cache Invalidation Strategy for Reader Nodes](#cache-invalidation-strategy-for-reader-nodes) section for details on cache invalidation in replicated setups


#### Cache Invalidation Strategy for Reader Nodes

Both Option A (Normalized Metadata Tables) and Option B (pgbson Document Metadata) require caching to achieve acceptable performance. In a replicated setup with reader nodes (replicas), cache invalidation becomes critical to ensure readers detect privilege changes replicated from the writer.

**Versioning System for Cache Invalidation:**

Implement a versioning system to ensure replicas detect stale cache:
- Add a `metadata_version` table with a single row containing a version number
- Every update to user/role information (createUser, grantRole, dropRole, etc.) increments the version number in the same transaction
- Each cache stores the version number it was built from
- Before using cache, compare cached version with current version in metadata_version table
- If versions differ, invalidate cache and rebuild from current metadata
- This ensures reader nodes detect changes replicated from the writer and refresh their cache accordingly

This versioning approach is simple, reliable, and works with PG's replication model where metadata changes are written on the primary and replicated to secondaries.

#### Option C: Two-Tier Hybrid System

**Description**: Use PG's native privilege system for operations that map naturally, and custom metadata tables for DocumentDB-specific privileges.

**Tier 1 - Native PG Privileges (Storage)**:

Store CRUD and basic DDL privilege mappings using PG's native ACL system:

```
MongoDB Privilege    →    PG Permission (What gets stored in PG ACLs)
------------------------------------------------------------------------
find                 →    SELECT (on tables)
insert               →    INSERT (on tables)
update               →    UPDATE (on tables)
remove               →    DELETE (on tables)
createCollection     →    CREATE (on schema)
dropCollection       →    DROP (on tables)
createIndex          →    CREATE (for indexes)
dropIndex            →    DROP (for indexes)
```

Example of what gets stored using standard PG GRANT:
```sql
-- These permissions are stored in PG's internal ACL structures
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA mydb TO user_role;
GRANT CREATE ON SCHEMA mydb TO user_role;
```

**Tier 2 - Custom Metadata Tables (Storage)**:

Store DocumentDB-specific privileges that don't map to PG in custom metadata tables (can use Option A or Option B structure):
- `bypassDocumentValidation`, `changeStream`, `collMod`, `convertToCapped`
- `createUser`, `createRole`, `grantRole`, `revokeRole`, `viewUser`, `viewRole`
- `enableSharding`, `addShard`, `moveChunk`, `replSetConfigure`
- `inprog`, `killop`, `serverStatus`, `collStats`, `dbStats`, `top`
- `setParameter`, `shutdown`, `logRotate`, `compact`, `fsync`
- All other privileges from Appendix A that don't have PG equivalents

**User/Role Identity Management**:
- Leverage PG's existing role system (stored in `pg_authid` catalog) for user identity
- DocumentDB users are actual PG roles, not just entries in custom tables
- Custom metadata tables reference PG roles by OID (Object Identifier) for stability

**Key Metadata Table for Maintaining MongoDB Semantics**:

The `user_roles` table is critical for maintaining MongoDB's database-scoped role grant semantics:

```sql
CREATE TABLE user_roles (
    user_oid OID NOT NULL,           -- References pg_authid.oid
    role_name TEXT NOT NULL,          -- e.g., "readWrite", "read", "dbAdmin"
    database_name TEXT NOT NULL,      -- Database scope: "sales", "marketing", etc.
    granted_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (user_oid, role_name, database_name)
);
```

**Example data showing MongoDB's database-scoped grants**:
```
| user_oid | role_name  | database_name |
|----------|------------|---------------|
| 16389    | readWrite  | sales         |  -- alice has readWrite on sales
| 16389    | read       | marketing     |  -- alice has read on marketing  
| 16390    | dbAdmin    | admin         |  -- bob has dbAdmin on admin
```

This structure enables:
- **Database-scoped role grants**: Same role can be granted to a user multiple times with different database contexts
- **MongoDB compatibility**: Directly represents `grantRolesToUser("alice", [{role: "readWrite", db: "sales"}])`
- **Query at enforcement time**: Check if user has specific role on specific database
- **Management operations**: `revokeRolesFromUser` knows exactly which grant to remove

**Pros**:
- Leverages PG's battle-tested, highly optimized ACL storage for common CRUD privileges
- Can query PG system catalogs for CRUD privilege information
- Enables legitimate direct SQL access for CRUD operations - users with proper PG ACL permissions can use SQL directly for administrative operations, analytics with BI tools, debugging, and performance analysis (when paired with enforcement that checks PG ACLs like Option D)

**Cons**:
- Two different storage systems to manage (PG ACLs + custom metadata tables)
- More complex data model - some privileges in PG catalogs, some in custom tables
- Requires understanding both PG's ACL system and custom metadata schema

**Note**: This storage mechanism can be used with different enforcement approaches. The Recommendation section describes using it with Option B (Extension Command Handlers) for enforcement, keeping PG ACLs synchronized to support direct SQL access while DocumentDB API access uses custom authorization.


---

### Design Dimension 2: Privilege Enforcement Mechanism

**Question**: Where and how do we check privileges before allowing operations?

#### Option A: Gateway Layer (pg_documentdb_gw)

**Description**: Implement privilege checks in the DocumentDB Gateway (Rust codebase) when MongoDB commands arrive at the protocol handler.

**How it works**:
- Gateway intercepts MongoDB commands from clients
- Before forwarding to PG extension, check privileges
- Query privilege metadata (either cached in Gateway or fetched from PG)
- Reject unauthorized requests immediately with MongoDB-compatible error

**Pros**:
- Security enforcement at the entry point allowing fail fast by rejecting unauthorized requests early (no PG overhead)
- Can return MongoDB-compatible error messages easily
- Can cache privileges in Gateway process memory for better performance
- Easier to implement DocumentDB-specific privilege logic in Gateway

**Cons**:
- Doesn't protect against bypassing Gateway (direct PG access via psql, etc.)
- Gateway needs access to privilege metadata (requires PG queries or caching)
- If privileges cached in Gateway, need cache invalidation mechanism

#### Option B: Extension Command Handlers

**Description**: Implement privilege checks in the extension command handlers after Gateway forwards commands but before actual execution.

Command handlers are C functions (e.g., `command_insert()`, `command_delete()`, `command_find_cursor_first_page()`) that process MongoDB commands forwarded from the Gateway. Each handler receives the MongoDB command as pgbson, builds the corresponding PostgreSQL query structures, and executes them. This enforcement approach would add privilege checking before query execution.

**How it works**:
- Each command handler checks privileges before proceeding
- First check privilege cache (stored in PG shared memory or per-backend cache)
- On cache miss, query privilege metadata tables using PostgreSQL's SPI (Server Programming Interface) - this is C API that allows extension code to execute SQL queries within the same database process
  - Example: `SPI_execute("SELECT ... FROM user_roles WHERE user_id = current_user ...")` to check if user has required privilege
  - Cache the result for subsequent operations
- Reject operations if user lacks required privileges
- Works even if Gateway is bypassed

**Pros**:
- Protects operations even if Gateway is bypassed

**Cons**:
- Checks happen later in the pipeline (after Gateway forwarding)
- Still doesn't protect against direct PG table access (someone doing raw SQL on DocumentDB tables)
- More invasive - need to add the check in all command handlers

#### Option C: PG Hooks

**Description**: Use PostgreSQL's hook system (`ProcessUtility_hook` for DDL operations and `ExecutorCheckPerms_hook` for DML operations) to intercept operations at the PG execution layer. All variants implement a **fail-closed security model** that blocks direct SQL access to DocumentDB tables.

**Common to all variants:**
- Hooks check if operation accesses DocumentDB tables (e.g., `documents_*` pattern)
- DocumentDB command context passed via session-level GUC variables
- If GUC context is missing (NULL) when accessing DocumentDB tables → block access with error
- If GUC context exists → perform DocumentDB privilege checking

**Key Advantage**: The primary benefit of Option C over Option B is the **fail-closed security model** that blocks unauthorized direct SQL access. Another benefit of some variants within this approach is that it allows centralization of the privilege checking and doesn't require changes in all command handlers in the extension.


##### Option C1: Gateway-Set Context

**Description**: Gateway sets DocumentDB command context via GUC variables before calling extension functions. Command handlers require **no modifications**.

**Implementation Approach: Shared Superuser Pool + SET ROLE**

**Architecture:**
- Gateway uses shared superuser connection pool for all clients
- DocumentDB users exist as PG roles with `NOLOGIN` privilege
- Gateway performs DocumentDB authentication separately (validates credentials against DocumentDB metadata)
- Gateway uses `SET ROLE` to impersonate authenticated user for privilege checking

**Authentication flow:**
1. Client connects to Gateway with DocumentDB credentials (`username`, `password`)
2. Gateway validates credentials against DocumentDB auth metadata (stored in PG)
3. If valid, Gateway uses shared superuser connection from pool
4. Gateway executes `SET ROLE <username>` to impersonate user for privilege checks

**GUC Security:**
- GUCs defined as `PGC_SUSET`
- Gateway's superuser connection can SET them
- Regular users cannot forge GUC values

**Gateway execution flow:**
```sql
-- Gateway uses shared superuser connection
SET ROLE alice;  -- Impersonate authenticated MongoDB user
SET documentdb.current_command = 'find';
SET documentdb.current_database = 'foo';
SET documentdb.current_collection = 'bar';
SELECT command_find_cursor_first_page(...);
RESET ROLE;  -- Return to superuser context
```

**DocumentDB user setup:**
```sql
-- DocumentDB users created as PG roles without login capability
CREATE ROLE alice NOLOGIN;
CREATE ROLE bob NOLOGIN;
-- These roles used only for privilege checking via SET ROLE, not authentication
```

**Pros:**
- DocumentDB users don't need PG passwords
- Cleaner separation between DocumentDB and PG authentication
- No per-user connection pool overhead
- Command handlers need no modifications
- Centralized context management in Gateway

**Cons:**
- **Loses PG authentication as defense layer**: Only Gateway authenticates to PG
- Requires Gateway architecture change from current per-user connection pool model
- Gateway authentication becomes sole authentication mechanism


##### Option C2: Extension-Set Context

**Description**: Extension command handlers set GUC context before executing queries. Works with existing per-user connection pools (no Gateway changes needed).

**How it works**:
1. Gateway forwards command to extension using existing per-user connection pool
2. Each command handler sets GUC context before executing queries:
   ```c
   // In command_find_cursor_first_page()
   SetConfigOption("documentdb.current_command", "find", PGC_USERSET, PGC_S_SESSION);
   SetConfigOption("documentdb.current_database", database_name, PGC_USERSET, PGC_S_SESSION);
   SetConfigOption("documentdb.current_collection", collection_name, PGC_USERSET, PGC_S_SESSION);
   
   // Execute query - hooks will fire and check privileges
   SPI_execute("SELECT * FROM documents_12345 WHERE ...");
   
   // Clear context
   SetConfigOption("documentdb.current_command", NULL, ...);
   ```
3. Hooks read GUCs and check privileges for `current_user` (the authenticated PG user)

**GUC Security:**
- GUCs can be `PGC_USERSET` since extension C code sets them (runs with internal privileges)
- Users attempting `SET documentdb.current_command = 'find'` could succeed, BUT:
  - Hooks validate DocumentDB command context matches actual operation
  - If user sets `current_command='find'` but tries DELETE, hooks detect mismatch
  - Fail-closed model: Missing context blocks access entirely

**Implementation scope:**
- **Requires modifying all command handlers** (like Option B)
- Each handler must add context-setting code before queries
- Similar implementation effort to Option B

**Pros:**
- Fail-closed security - Blocks direct SQL access to DocumentDB tables (primary advantage over Option B)
- No Gateway architecture changes needed
- Works with existing per-user connection pool model
- Preserves per-user PG authentication

**Cons:**
- Requires modifying all command handlers (not truly "centralized setup")
- Similar implementation effort to Option B


##### Option C: Complete Privilege Check Flow Example

**MongoDB Protocol Access (authorized):**
```
1. Gateway receives MongoDB command: db.foo.find({...})
2. Gateway forwards to extension: command_find_cursor_first_page(database="foo", findSpec=<bson>)
3. [C1 variants] Gateway sets GUCs / [C2 variant] Extension sets GUCs
5. PG executor starts, calls ExecutorCheckPerms_hook
6. Hook detects DocumentDB table access, reads GUC variables
7. Hook checks: does current_user have "find" privilege on {db: "foo", collection: "bar"}?
8. If yes: allow operation; if no: raise PermissionDenied error
9. Context cleared (by Gateway in C1, by extension in C2)
```

**Direct SQL Access (blocked):**
```
1. User executes: SELECT * FROM api_data.documents_12345;
2. PG executor starts, calls ExecutorCheckPerms_hook
3. Hook detects DocumentDB table (documents_* pattern)
4. Hook reads GUC variables - finds documentdb.current_command = NULL (no MongoDB context)
5. Hook blocks access with error: "Direct SQL access to DocumentDB tables is not permitted"
```

**Coverage:**
Hooks can enforce privileges for **all DocumentDB commands** as long as context is properly set (by Gateway in C1, by handlers in C2). The hooks read MongoDB command context from GUCs and perform privilege checking - they don't care how the context was set.


##### Option C: Pros and Cons Summary

**Common Pros (all variants):**
- Fail-closed security model blocks direct SQL access to DocumentDB tables
- Centralized privilege checking logic in 2 hooks (easier to maintain than scattered checks in 50+ handlers)

**Common Cons (all variants):**
- Blocks all direct SQL access (may complicate debugging)
  - Mitigation: Implement superuser bypass or admin flag for privileged access

---

#### Option D: Hybrid Enforcement

**Description**: Hybrid enforcement approach that leverages native PG ACL checks for CRUD operations (fast path) and custom privilege checks for DocumentDB-specific operations. **Works in conjunction with Dimension 1 Option C (Two-Tier Hybrid Storage)**.

**How it works**:

1. **For CRUD operations** (`find`, `insert`, `update`, `remove`): Check native PG ACLs first
   - PG's internal permission system handles SELECT, INSERT, UPDATE, DELETE checks
   - Fast path - no custom code overhead for common operations
   - Result: If user has PG permissions, operation allowed; otherwise blocked

2. **For DocumentDB-specific operations**: Check custom metadata tables
   - Operations like `changeStream`, `collMod`, `createUser`, etc.
   - Query custom metadata (using approach from Options A, B, or C of this dimension)
   - Result: If user has required privilege in metadata, operation allowed; otherwise blocked

3. **Use PG roles for user identity and basic role hierarchy**:
   - Leverage PG's existing role system for managing which users/roles exist
   - Use PG's native role membership for basic role hierarchy
   - DocumentDB users are actual PG roles, not just entries in custom tables

4. **Store privilege assignments in both systems**:
   - CRUD privileges: Stored in PG's ACL (via GRANT/REVOKE commands)
   - DocumentDB-specific privileges: Stored in custom metadata tables
   - Custom metadata references PG roles by OID for stability

5. **Critical implementation challenge - database-scoped role grants**:
   - MongoDB grants roles per-database: `grantRolesToUser("alice", [{role: "readWrite", db: "sales"}])`
   - PG role membership is cluster-wide: `GRANT readwrite_role TO alice` applies to ALL databases
   
   **How Option D maintains MongoDB's database-scoped semantics**:
   
   Uses the `user_roles` table from Option C storage (see [Option C: Two-Tier Hybrid System](#option-c-two-tier-hybrid-system)):
   ```sql
   -- user_roles table structure
   CREATE TABLE user_roles (
       user_oid OID NOT NULL,           -- References pg_authid.oid  
       role_name TEXT NOT NULL,          -- e.g., "readWrite", "read"
       database_name TEXT NOT NULL,      -- Database scope: "sales", "marketing"
       granted_at TIMESTAMPTZ DEFAULT now(),
       PRIMARY KEY (user_oid, role_name, database_name)
   );
   ```
   
   **Implementation approach when `grantRolesToUser` is called**:
   1. **Store in custom metadata**: INSERT into `user_roles` table
      - Example: `INSERT INTO user_roles VALUES (alice_oid, 'readWrite', 'sales')`
      - This tracks that alice has readWrite role specifically on sales database
   
   2. **Translate to PG permissions**: Dynamically issue PG GRANT commands
      - For existing tables: `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales TO alice`
      - For future tables: `ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO alice`
   
   3. **At runtime privilege checking**:
      - **For CRUD operations**: PG's ACL handles checks directly (fast path - no metadata query)
        - alice tries `SELECT * FROM sales.documents_123` → PG checks ACL → allowed
        - alice tries `SELECT * FROM marketing.documents_456` → PG checks ACL → denied (no permission)
      - **For DocumentDB-specific operations**: Query `user_roles` table
        - Check if alice has required role on the target database
   
   **Custom metadata still required for**:
   - **Management operations**: 
     * `revokeRolesToUser("alice", [{role: "readWrite", db: "sales"}])` queries `user_roles` to know which PG REVOKEs to issue
     * DELETE from `user_roles` WHERE user_oid=alice AND role_name='readWrite' AND database_name='sales'
   - **Reporting operations**:
     * `usersInfo("alice")` queries `user_roles` to show: alice has readWrite on sales, read on marketing
   - **Role hierarchy tracking**: Which roles inherit from other roles (stored in separate metadata)

6. **New object handling challenge**: When new tables are created, they need appropriate permissions. Three approaches:

   **Approach 1: Dynamic ALTER DEFAULT PRIVILEGES with Schema-Scoped Owner Roles**
   - Use schema-scoped owner roles to manage ALTER DEFAULT PRIVILEGES efficiently
   - Create a marker role per schema (e.g., `sales_table_creator`) and grant it to all roles that can create tables in that schema
   - When granting privileges to users, reference the schema's owner role:
     * `ALTER DEFAULT PRIVILEGES FOR ROLE sales_table_creator IN SCHEMA sales GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO alice`
   - Adding new creator roles only requires granting them membership in the appropriate owner role (O(1) operation)
   - Pros:
     * Pure native PG mechanism, no event trigger overhead on table creation
     * Efficient management: Adding new creator roles is O(1) - just grant owner role membership
     * Per-operation costs: Grant/revoke role is O(1), create user with R roles is O(R)
     * Automatic permission grants for future tables
   - Cons:
     * State management complexity: Must track which ALTER DEFAULT PRIVILEGES exist for cleanup during revoke operations
     * Must coordinate schema-scoped owner roles with creator role lifecycle management
   - Note: Grouping users into privilege set roles was considered to reduce ALTER DEFAULT PRIVILEGES statements, but rejected due to increased complexity with minimal benefit, especially when handling MongoDB's collection-scoped permissions which would require a privilege set role per unique (database, collection, privilege-set) combination.
   - See [Appendix B](#appendix-b-detailed-sql-for-alter-default-privileges-approach) for detailed SQL examples of each operation

   **Approach 2: Event triggers only**
   - Use CREATE TABLE event triggers to dynamically grant permissions
   - How it works:
     * When CREATE TABLE fires in a schema, event trigger queries custom metadata
     * For each user with roles on that database, issue appropriate GRANT statements
     * Example: `GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE sales.new_table TO alice`
   - Pros: Works regardless of who creates table, centralized permission logic
   - Cons:
     * Custom trigger code adds overhead to every table creation
     * Performance degrades with user count: O(U × P) where U = number of users with access to the database and P = number of GRANT statements per user
     * High-user scenarios problematic: 100 users = 100+ GRANT statements per table creation
     * Synchronous blocking: Event trigger must complete before CREATE TABLE returns

   **Approach 3: Hybrid (ALTER DEFAULT PRIVILEGES + Event Triggers)**
   - Set ALTER DEFAULT PRIVILEGES for common creator roles
   - Use event triggers as fallback for other roles
   - Pros: Optimizes common case while handling edge cases
   - Cons: Most complex option, requires maintaining both mechanisms

**Pros**:
- Best performance for CRUD operations - leverages PG's optimized ACL checks
- No custom code overhead for common database operations
- Allows legitimate direct SQL access for users with proper PG permissions - enables administrative operations, analytics with BI tools, debugging, performance analysis, and SQL-based workflows while maintaining security through PG's native ACL system

**Cons**:
- Two privilege systems to keep synchronized (PG ACLs + custom metadata)
- **Synchronization complexity**:
  * When `grantRolesToUser` called: must UPDATE custom metadata AND execute PG GRANT commands atomically
  * When `revokeRolesFromUser` called: must UPDATE custom metadata AND execute PG REVOKE commands atomically
  * If either operation fails partially, systems become inconsistent
  * If someone manually issues PG GRANT/REVOKE bypassing DocumentDB commands, PG's ACL changes but custom metadata doesn't know
- New object handling requires choosing between three approaches (ALTER DEFAULT PRIVILEGES, event triggers, or hybrid), each with trade-offs. With schema-scoped owner roles and ALTER DEFAULT PRIVILEGES, per-operation overhead is minimal (3-4 SQL statements per grant/revoke), but still requires coordination between PG ACLs and custom metadata
- More complex testing to ensure both systems work together

**Note**: This option requires using Dimension 1 Option C (Two-Tier Hybrid Storage) to store privileges appropriately.

---

### Recommendation

DocumentDB will only allow user/role creation in the admin database and not any other database. There is little value in allowing user/role creation across databases.

Privileges corresponding to API's that DocumentDB will not implement will not be supported. For example, planCacheIndexFilter, querySettings etc.

**Approach: Custom Authorization with PG ACL Synchronization**

We will implement custom authorization enforcement using **Option B (pgbson Document Metadata) for storage** combined with **Option B (Extension Command Handlers) for enforcement**. All DocumentDB API access (through Gateway or Extension command handlers) will be validated through authorization checks implemented directly in the command handlers.

To support legitimate direct SQL access to DocumentDB tables, we will maintain PostgreSQL ACL synchronization using the mechanisms described in **Option C (Two-Tier Hybrid Storage)**. This means:

1. **For CRUD privileges** (`find`, `insert`, `update`, `remove`): Store permissions in both custom metadata AND sync them to PG's native ACL system using GRANT/REVOKE and ALTER DEFAULT PRIVILEGES
   - DocumentDB API access: Custom authorization checks the pgbson metadata in command handlers
   - Direct SQL access: PG's native ACL enforcement provides protection

2. **For custom DocumentDB privileges** (those without PG equivalents): Store in pgbson metadata only
   - These privileges are only enforced when accessing through DocumentDB APIs
   - Direct SQL access bypasses these checks (as PG has no equivalent privileges to enforce)

This approach provides:
- **Strong authorization** for all DocumentDB API access through custom enforcement in command handlers
- **Legitimate direct SQL access** for administrative operations, analytics with BI tools, debugging, and performance analysis
- **Simple architecture** with no hook complexity - checks happen where operations are initiated

**New Object Handling:**

We will use ALTER DEFAULT PRIVILEGES with Schema-Scoped Owner Roles (Appendix B) to automatically grant permissions on newly created tables.

**Phased Implementation Plan:**

This is a pragmatic, low-risk implementation approach:

**Phase 1: Build custom authorization (temporarily use PG ACLs for CRUD)**
- While building and stabilizing the custom authorization infrastructure (required for non-CRUD privileges), temporarily use PG's native ACL enforcement for CRUD operations
- This allows us to focus on:
  - Building the pgbson metadata storage layer
  - Implementing privilege checking logic in command handlers for DocumentDB-specific privileges
  - Establishing the PG ACL synchronization mechanism

**Phase 2: Migrate to Unified Custom Authorization**
- Once the custom authorization system is stable and performance-validated for non-CRUD privileges, migrate CRUD privilege enforcement to the custom system
- Add authorization checks for CRUD operations to all relevant command handlers
- This migration will be transparent to users - no API changes or user-visible impact
- Benefits of consolidation:
  - Single authorization mechanism for all privileges
  - Consistent enforcement semantics across all operations
  - Greater flexibility for MongoDB-specific authorization patterns
  - Simplified debugging and maintenance

**This is a Two-Way Door Decision for CRUD Operations:**

The choice to temporarily use PG's ACL system for CRUD privilege enforcement during Phase 1 is pragmatic and reversible. Once we build and stabilize our custom authorization infrastructure (which is required for non-CRUD privileges regardless), we can migrate CRUD privilege enforcement to the custom system. This migration path is straightforward and has no user-visible impact - all changes are internal to the enforcement mechanism.

**Performance Validation:**
- During Phase 1, we will benchmark custom authorization performance for non-CRUD privileges
- Before Phase 2 migration, we will validate that CRUD operation performance with custom authorization meets production requirements
- If performance is acceptable, we consolidate to a single enforcement mechanism

---

## Appendix A: Complete List of MongoDB Privileges

Based on MongoDB's official [Privilege Actions documentation](https://www.mongodb.com/docs/manual/reference/privilege-actions/), the following is a comprehensive list of all MongoDB privilege actions organized by category.

**Legend:**
- ✅ = Maps directly to PG privilege (e.g., SELECT, INSERT, UPDATE, DELETE, CREATE, DROP)
- ⚠️ = Partial mapping possible but with RBAC semantic differences
- ❌ = No PG equivalent, requires custom implementation

### Query and Write Actions
- ✅ `find` - Query documents (maps to PG SELECT)
- ✅ `insert` - Insert documents (maps to PG INSERT)
- ✅ `remove` - Delete/remove documents (maps to PG DELETE)
- ✅ `update` - Update documents (maps to PG UPDATE)
- ❌ `bypassDocumentValidation` - Bypass schema validation on commands that support it
- ❌ `useUUID` - Execute commands using UUID as namespace

### Database Management Actions
- ❌ `changeCustomData` - Change custom information of any user
- ❌ `changeOwnCustomData` - Change own custom information
- ⚠️ `changeOwnPassword` - Change own password (PG has ALTER ROLE but different semantics)
- ⚠️ `changePassword` - Change password of any user (PG has ALTER ROLE but different semantics)
- ✅ `createCollection` - Explicitly create collections (maps to CREATE on schema)
- ✅ `createIndex` - Create indexes on collections (maps to CREATE for indexes)
- ⚠️ `createRole` - Create new roles in the database (maps to CREATEROLE but database-scoped vs cluster-wide)
- ⚠️ `createUser` - Create new users in the database (maps to CREATEROLE but database-scoped vs cluster-wide)
- ✅ `dropCollection` - Drop collections (maps to DROP on tables)
- ⚠️ `dropRole` - Delete any role from the database (maps to DROP ROLE but database-scoped vs cluster-wide)
- ⚠️ `dropUser` - Remove any user from the database (maps to DROP ROLE but database-scoped vs cluster-wide)
- ❌ `enableProfiler` - Enable database profiler
- ❌ `grantRole` - Grant any role to any user from any database (see Appendix B for detailed differences)
- ⚠️ `killCursors` - Kill cursors (PG: users can always CLOSE their own cursors without privileges, but cursors are session-local and auto-close with transactions)
- ❌ `killAnyCursor` - Kill any cursor including those created by other users (no PG equivalent - cannot kill other users' cursors)
- ❌ `planCacheIndexFilter` - Manage plan cache index filters
- ❌ `querySettings` - Manage query settings (MongoDB 8.0+)
- ❌ `revokeRole` - Remove any role from any user from any database (see Appendix B for detailed differences)
- ❌ `setAuthenticationRestriction` - Specify authentication restrictions for users/roles
- ❌ `setFeatureCompatibilityVersion` - Set feature compatibility version
- ❌ `unlock` - Unlock database after fsync lock
- ❌ `viewRole` - View information about any role in the database
- ❌ `viewUser` - View information of any user in the database

### Deployment Management Actions
- ❌ `authSchemaUpgrade` - Perform authentication schema upgrades
- ❌ `cleanupOrphaned` - Clean up orphaned data
- ❌ `cpuProfiler` - Enable and use CPU profiler
- ⚠️ `inprog` - View pending and active operations (partial mapping to SELECT on pg_stat_activity)
- ❌ `invalidateUserCache` - Invalidate user cache
- ⚠️ `killop` - Kill operations (partial mapping to pg_terminate_backend/pg_cancel_backend)
- ❌ `planCacheRead` - Read plan cache statistics
- ❌ `planCacheWrite` - Clear plan cache

### Change Stream Actions
- ❌ `changeStream` - Create change streams on collections or databases

### Replication Actions
- ❌ `appendOplogNote` - Append notes to oplog
- ❌ `replSetConfigure` - Configure replica sets
- ❌ `replSetGetConfig` - View replica set configuration
- ❌ `replSetGetStatus` - View replica set status
- ❌ `replSetHeartbeat` - Perform replica set heartbeat
- ❌ `replSetStateChange` - Change replica set state
- ❌ `resync` - Resync replica set members

### Sharding Actions
- ❌ `addShard` - Add shards to cluster
- ❌ `analyzeShardKey` - Analyze shard keys
- ❌ `checkMetadataConsistency` - Check metadata consistency (MongoDB 7.0+)
- ❌ `clearJumboFlag` - Clear chunk jumbo flag
- ❌ `enableSharding` - Enable sharding on databases/collections
- ❌ `refineCollectionShardKey` - Refine collection shard key
- ❌ `moveCollection` - Move collections (MongoDB 8.0+)
- ❌ `reshardCollection` - Reshard collections (MongoDB 5.0+)
- ❌ `unshardCollection` - Unshard collections (MongoDB 8.0+)
- ❌ `flushRouterConfig` - Flush router configuration
- ❌ `getClusterParameter` - Get cluster parameters (MongoDB 6.0+)
- ❌ `getShardMap` - Get shard map
- ❌ `listShards` - List shards
- ❌ `moveChunk` - Move chunks between shards
- ❌ `removeShard` - Remove shards from cluster
- ❌ `shardedDataDistribution` - View sharded data distribution (MongoDB 6.0.3+)
- ❌ `shardingState` - View sharding state
- ❌ `splitChunk` - Split chunks
- ❌ `transitionFromDedicatedConfigServer` - Transition from dedicated config server (MongoDB 8.0+)
- ❌ `transitionToDedicatedConfigServer` - Transition to dedicated config server (MongoDB 8.0+)

### Server Administration Actions
- ❌ `applicationMessage` - Write to application message log
- ❌ `bypassWriteBlockingMode` - Bypass write blocking mode
- ❌ `bypassDefaultMaxTimeMS` - Bypass default max time limit (MongoDB 8.0+)
- ❌ `closeAllDatabases` - Close all databases
- ⚠️ `collMod` - Modify collection options (partial mapping to ALTER TABLE but different options)
- ❌ `compact` - Compact collections and run autoCompact
- ❌ `compactStructuredEncryptionData` - Compact encrypted data
- ❌ `connPoolSync` - Sync connection pool
- ❌ `convertToCapped` - Convert collections to capped
- ❌ `dropConnections` - Drop connections
- ✅ `dropDatabase` - Drop databases (maps to DROP DATABASE)
- ✅ `dropIndex` - Drop indexes (maps to DROP INDEX)
- ❌ `forceUUID` - Create collections with user-defined UUIDs
- ❌ `fsync` - Force filesystem sync
- ❌ `getDefaultRWConcern` - Get default read/write concern
- ❌ `getParameter` - Get server parameters
- ❌ `hostInfo` - Get server host information
- ❌ `oidReset` - Reset ObjectID random string
- ❌ `logRotate` - Rotate logs
- ❌ `reIndex` - Rebuild indexes
- ⚠️ `renameCollectionSameDB` - Rename collections within same database (maps to ALTER TABLE RENAME but different scope semantics)
- ❌ `rotateCertificates` - Rotate TLS certificates
- ❌ `setDefaultRWConcern` - Set default read/write concern
- ❌ `setParameter` - Set server parameters
- ❌ `setUserWriteBlockMode` - Set user write blocking mode
- ❌ `shutdown` - Shutdown server
- ❌ `touch` - Load data into memory

### Session Actions
- ⚠️ `impersonate` - Kill sessions with user/role patterns (PG has SET ROLE but different semantics)
- ⚠️ `listSessions` - List all or specific user sessions (partial mapping to SELECT on pg_stat_activity)
- ⚠️ `killAnySession` - Kill any session (partial mapping to pg_terminate_backend)

### MongoDB Atlas Search Actions
(Not applicable for on-premises deployments)
- ❌ `createSearchIndexes` - Create search indexes
- ❌ `dropSearchIndex` - Drop search indexes
- ❌ `listSearchIndexes` - List search indexes
- ❌ `updateSearchIndex` - Update search indexes

### Diagnostic Actions
- ⚠️ `collStats` - View collection statistics (partial mapping to pg_stat_user_tables, pg_class functions)
- ⚠️ `connPoolStats` - View connection pool statistics (partial mapping to pg_stat_database)
- ❌ `dbHash` - Get database hash
- ⚠️ `dbStats` - View database statistics (partial mapping to pg_database, pg_stat_database)
- ❌ `getCmdLineOpts` - Get command line options
- ❌ `getLog` - Get log entries
- ⚠️ `indexStats` - View index statistics (partial mapping to pg_stat_user_indexes)
- ❌ `listClusterCatalog` - List cluster catalog (on admin database)
- ⚠️ `listDatabases` - List all databases (partial mapping to SELECT on pg_database)
- ⚠️ `listCollections` - List collections in database (partial mapping to SELECT on pg_tables/pg_class)
- ⚠️ `listIndexes` - List indexes on collection (partial mapping to SELECT on pg_indexes)
- ❌ `queryStatsRead` - Read query statistics
- ❌ `queryStatsReadTransformed` - Read transformed query statistics
- ⚠️ `serverStatus` - View server status (partial mapping to pg_stat_* views)
- ❌ `validate` - Validate collections and database metadata
- ⚠️ `top` - View operation statistics (partial mapping to pg_stat_statements, pg_stat_activity)

### Internal Actions
- ❌ `anyAction` - Allow any action (superuser-like, but grantable and resource-scoped unlike PG superuser)
- ❌ `internal` - Internal system actions
- ❌ `applyOps` - Apply oplog operations

---

## Appendix B: SQL Patterns for PG ACL Synchronization

This appendix provides SQL examples for synchronizing CRUD privileges from our custom metadata (Option B - pgbson documents) to PostgreSQL's native ACL system. This synchronization enables direct SQL access while maintaining custom authorization for DocumentDB API access.

The patterns use ALTER DEFAULT PRIVILEGES with Schema-Scoped Owner Roles for efficient privilege management.

This appendix provides detailed SQL examples for implementing Approach 1 (Dynamic ALTER DEFAULT PRIVILEGES with Schema-Scoped Owner Roles) from the hybrid enforcement option (Option D).

### Schema-Scoped Owner Role Pattern

The core concept is using marker roles per schema that all table creator roles become members of:

```sql
-- Create schema-scoped owner role (marker role for privilege management)
CREATE ROLE sales_table_creator NOLOGIN;
CREATE ROLE marketing_table_creator NOLOGIN;

-- Grant creator roles membership in their schema's owner role
GRANT sales_table_creator TO app_service;
GRANT sales_table_creator TO admin_user;
GRANT marketing_table_creator TO marketing_app;
```

### User/Role Management Operations

#### 1. Grant Role to User
**MongoDB Command**: `db.grantRolesToUser("alice", [{role: "readWrite", db: "sales"}])`

**SQL Execution** (3 statements):
```sql
-- Store in custom metadata
INSERT INTO user_roles (user_oid, role_name, database_name) 
VALUES (alice_oid, 'readWrite', 'sales');

-- Set default privileges for future tables (references owner role)
ALTER DEFAULT PRIVILEGES FOR ROLE sales_table_creator IN SCHEMA sales
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO alice;

-- Grant on existing tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales TO alice;
```

**Complexity**: O(1)

#### 2. Revoke Role from User
**MongoDB Command**: `db.revokeRolesFromUser("alice", [{role: "readWrite", db: "sales"}])`

**SQL Execution** (4 statements):
```sql
-- Query metadata to determine what to revoke
SELECT * FROM user_roles 
WHERE user_oid = alice_oid 
  AND role_name = 'readWrite' 
  AND database_name = 'sales';

-- Revoke default privileges
ALTER DEFAULT PRIVILEGES FOR ROLE sales_table_creator IN SCHEMA sales
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM alice;

-- Revoke from existing tables
REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales FROM alice;

-- Delete from metadata
DELETE FROM user_roles 
WHERE user_oid = alice_oid 
  AND role_name = 'readWrite' 
  AND database_name = 'sales';
```

**Complexity**: O(1)

#### 3. Create User with Multiple Roles
**MongoDB Command**: `db.createUser({user: "alice", pwd: "...", roles: [{role: "readWrite", db: "sales"}, {role: "read", db: "marketing"}]})`

**SQL Execution** (1 + 2R statements, where R = number of roles):
```sql
-- Create the user (PG role)
CREATE ROLE alice LOGIN PASSWORD '...';

-- For each role (R=2 in this example):

-- First role: sales readWrite
INSERT INTO user_roles VALUES (alice_oid, 'readWrite', 'sales');
ALTER DEFAULT PRIVILEGES FOR ROLE sales_table_creator IN SCHEMA sales
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO alice;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales TO alice;

-- Second role: marketing read
INSERT INTO user_roles VALUES (alice_oid, 'read', 'marketing');
ALTER DEFAULT PRIVILEGES FOR ROLE marketing_table_creator IN SCHEMA marketing
  GRANT SELECT ON TABLES TO alice;
GRANT SELECT ON ALL TABLES IN SCHEMA marketing TO alice;
```

**Complexity**: O(R) where R = number of roles

#### 4. Drop User
**MongoDB Command**: `db.dropUser("alice")`

**SQL Execution** (varies based on roles user has):
```sql
-- Query all roles for this user
SELECT role_name, database_name FROM user_roles WHERE user_oid = alice_oid;

-- For each role, revoke (similar to operation #2)
-- If alice has 3 roles, execute revoke operations for each

-- Finally drop the role (PG automatically cleans up ALTER DEFAULT PRIVILEGES references)
DROP ROLE alice;

-- Delete metadata
DELETE FROM user_roles WHERE user_oid = alice_oid;
```

**Complexity**: O(R) where R = number of roles the user has

### Creator Role Management

#### 5. Add New Creator Role
When granting CREATE privilege to a new role:

**SQL Execution** (2 statements):
```sql
-- Grant CREATE privilege on the schema
GRANT CREATE ON SCHEMA sales TO new_creator;

-- Add to schema's owner role (this automatically applies all existing ALTER DEFAULT PRIVILEGES)
GRANT sales_table_creator TO new_creator;
```

**Complexity**: O(1) - No ALTER DEFAULT PRIVILEGES updates needed!

**Key Advantage**: All existing ALTER DEFAULT PRIVILEGES that reference `sales_table_creator` automatically apply to `new_creator` through role membership.

#### 6. Drop Creator Role

**SQL Execution** (2 statements):
```sql
-- Remove from owner role first
REVOKE sales_table_creator FROM old_creator;

-- Drop the role
DROP ROLE old_creator;
```

**Complexity**: O(1)

### Custom Role Operations

#### 7. Update Role Privileges
**MongoDB Command**: `db.updateRole("customRole", {privileges: [...]})`

When changing what privileges a role provides, must update for all users with that role:

**SQL Execution** (varies based on users with the role):
```sql
-- Query all users with this role
SELECT user_oid, database_name FROM user_roles WHERE role_name = 'customRole';

-- For each user with the role (U users):
  -- Revoke old privileges
  ALTER DEFAULT PRIVILEGES FOR ROLE db_table_creator IN SCHEMA db
    REVOKE <old privileges> FROM user;
  REVOKE <old privileges> ON ALL TABLES IN SCHEMA db FROM user;
  
  -- Grant new privileges
  ALTER DEFAULT PRIVILEGES FOR ROLE db_table_creator IN SCHEMA db
    GRANT <new privileges> TO user;
  GRANT <new privileges> ON ALL TABLES IN SCHEMA db TO user;
```

**Complexity**: O(U) where U = number of users with that role

#### 8. Drop Custom Role
**MongoDB Command**: `db.dropRole("customRole")`

**SQL Execution**:
```sql
-- Query all users with this role
SELECT user_oid, database_name FROM user_roles WHERE role_name = 'customRole';

-- For each user, revoke (similar to operation #2)

-- Delete role metadata
DELETE FROM role_privileges WHERE role_name = 'customRole';
DELETE FROM user_roles WHERE role_name = 'customRole';
```

**Complexity**: O(U) where U = number of users with that role

### Schema Operations

#### 9. Create New Schema/Database
**MongoDB**: First use of a new database (implicit creation)

**SQL Execution** (3 statements):
```sql
-- Create the schema
CREATE SCHEMA new_database;

-- Create its owner role
CREATE ROLE new_database_table_creator NOLOGIN;

-- Grant schema ownership (optional, for management)
ALTER SCHEMA new_database OWNER TO documentdb_admin;
```

**Complexity**: O(1)

#### 10. Drop Schema
**MongoDB Command**: `db.dropDatabase()`

**SQL Execution** (2 statements):
```sql
-- Drop the schema (CASCADE removes tables and associated privileges)
DROP SCHEMA old_database CASCADE;

-- Drop its owner role
DROP ROLE old_database_table_creator;

-- Note: PG automatically cleans up ALTER DEFAULT PRIVILEGES referencing dropped schema/role
```

**Complexity**: O(1)

### Summary Table

| Operation | SQL Statements | Complexity | Notes |
|-----------|---------------|------------|-------|
| Grant role to user | 3 | O(1) | Uses schema owner role |
| Revoke role from user | 4 | O(1) | Query + revoke + cleanup |
| Create user with R roles | 1 + 2R | O(R) | Per-role operations |
| Drop user with R roles | 2R + 2 | O(R) | Revoke all roles first |
| Add creator role | 2 | O(1) | Just grant owner role membership |
| Drop creator role | 2 | O(1) | Revoke membership first |
| Update role (U users have it) | 4U | O(U) | Must update all users |
| Drop role (U users have it) | 2U + 2 | O(U) | Revoke from all users |
| Create schema | 3 | O(1) | Schema + owner role |
| Drop schema | 2 | O(1) | Auto cleanup by PG |

### Key Insights

1. **Schema-scoped owner roles eliminate O(C) complexity**: Without owner roles, adding a new creator would require updating all P ALTER DEFAULT PRIVILEGES statements. With owner roles, it's just one GRANT statement.

2. **Most common operations are O(1)**: Grant, revoke, and creator management are all constant time.

3. **Only role definition changes affect multiple users**: Operations like `updateRole` that change what a role provides must update all users with that role, making them O(U).

4. **PostgreSQL handles cleanup automatically**: When dropping schemas or roles, PostgreSQL's catalog system automatically cleans up related ALTER DEFAULT PRIVILEGES entries.
