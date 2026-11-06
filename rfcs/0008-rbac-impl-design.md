# DocumentDB RBAC Implementation Overview

## On-Disk Storage

### Users Table

```
CREATE TABLE documentdb_api_catalog.user (
    user_name TEXT REFERENCES pg_roles(rolname) ON DELETE CASCADE,
    user_data pgbson,
    PRIMARY KEY (user_name)
);

-- index for updates when a custom role is deleted
CREATE INDEX IF NOT EXISTS idx_user_roles
    ON documentdb_api_catalog.users(user_data.roles); 
```

Sample Entry:

```
| **user_name** | **user_data**
| admin     | {roles: [
                {"db":"test", "role":"write"}, 
                {"db": "admin", "role":"readAnyDatabase"}
               ],
               comment: "..."}
```

The users table references the Postgres role associated with the user, and stores the relevant user data in a bson object. The user_data object will store the roles associated with the user in a list of database/role name pairs (e.g. `roles``:`` ``[{"db":``"test", "role":``"write"``},`` ``{"db":``"admin", "role":``"readAnyDatabase"``}]`). Additional fields associated with the user can be added in the future, such as custom data, command, authenticationRestrictions (see: https://www.mongodb.com/docs/manual/reference/command/usersInfo/#output)

### Roles Table

```
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.roles (
    pg_role_name TEXT REFERENCES pg_roles(rolname) ON DELETE CASCADE,
    roles documentdb_core.bson NOT NULL
);

-- Index for role lookup
CREATE INDEX IF NOT EXISTS idx_roles
    ON documentdb_api_catalog.roles(roles.database, roles.rolename); 
    
-- Index for role inheritance lookup
CREATE INDEX IF NOT EXISTS idx_roles_parents
    ON documentdb_api_catalog.roles(roles.roles); 
```

Roles are stored with a role name, and a database as a primary key. Built in roles have the field “is_builtin”, which we will use to prevent the customer from modifying them. 

```
{
  "role": "dbAdmin",
  "database": "admin",
  "is_builtin": true,
  "description": "Provides database administration privileges",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": [
        "find", "insert", "update", "remove",
        "createCollection", "dropCollection",
        "createIndex", "dropIndex",
        "collMod", "collStats", "dbStats",
        "listCollections", "listIndexes"
      ]
    }
  ],
  "roles": []
}
```

Built-in roles have their definitions stored in the code, and are only added to the roles table as needed.

## In Memory Structors

We will create the following constants and in memory structors.

### PrivilegeAction Enum

Lists all the MongoDb privilege actions, https://www.mongodb.com/docs/manual/reference/privilege-actions/.

```
typedef enum PrivilegeAction {
    PRIV_FIND = 0,
    PRIV_INSERT,
    PRIV_UPDATE,
    ...
    PRIV_MAX  /* Keep this last for bitmap sizing */
} PrivilegeAction;

PrivilegeAction privilege_action_from_string(const char *str)

const char* privilege_action_to_string(PrivilegeAction action)
```

### Privileges (Bitmap)

Bitmap for storing and comparing privileges on any action

```
#define PRIVILEGE_SET_SIZE ((PRIV_MAX + 31) / 32)

typedef struct Privileges {
    uint32 bits[PRIVILEGE_SET_SIZE];
} PrivilegeSet;
```

### Role

```
#define MAX_DATABASE_NAME_LEN 64
#define MAX_ROLE_NAME_LEN 64

typedef struct Role{
    char database[MAX_DATABASE_NAME_LEN];
    char role[MAX_COLLECTION_NAME_LEN];
} Resource;
```

### Resource

```
#define MAX_DATABASE_NAME_LEN 64
#define MAX_COLLECTION_NAME_LEN 255

typedef struct Resource {
    char database[MAX_DATABASE_NAME_LEN];
    char collection[MAX_COLLECTION_NAME_LEN];
} Resource;
```

### Resource Privileges

```
typedef struct ResourcePrivileges {
    Resource resource;
    PrivilegeSet privileges;
} ResourcePrivilege;
```

### Resource Privileges Set

```
typedef struct ResourcePrivilegesSet {
    ResourcePrivilege **items;
    int count;
    int capacity;
} ResourcePrivilegeSet;
```

## Role and User Management Functions  (Built-in roles only)

These are functions that interact with the roles data stored in the tables. They are ment to be called as part of the customer facing user commands. Custom roles support will be added later.

```
bool removeRolesFromUser(const char *username, pgbson *roles_bson);

bool removeAllRolesFromUser(const char *username);

bool addRolesToUser(const char *username, pgbson *roles_bson);

bool setRolesForUser(const char *username, pgbson *roles_bson);

pgbson* getRolesForUser(const char *username);

ResourcePrivilegesSet* getResourcePrivilegeSetForRoles(pgbson *roles_bson);

ResourcePrivilegesSet* getResourcePrivilegeSetForUser(const char *username);
```

## Create / Update Customer Facing Commands (Built-in roles only)

Implement the mongo commands for user management, these implement the calls that come from the Gateway and do the BSON parsing / response:

* [`grantRolesToUser`](https://www.mongodb.com/docs/manual/reference/command/grantRolesToUser/#mongodb-dbcommand-dbcmd.grantRolesToUser)
* [`revokeRolesFromUser`](https://www.mongodb.com/docs/manual/reference/command/revokeRolesFromUser/#mongodb-dbcommand-dbcmd.revokeRolesFromUser)

Update existing user management commands to use the new system

* [`createUser`](https://www.mongodb.com/docs/manual/reference/command/createUser/#mongodb-dbcommand-dbcmd.createUser)
* [`dropAllUsersFromDatabase`](https://www.mongodb.com/docs/manual/reference/command/dropAllUsersFromDatabase/#mongodb-dbcommand-dbcmd.dropAllUsersFromDatabase)
* [`dropUser`](https://www.mongodb.com/docs/manual/reference/command/dropUser/#mongodb-dbcommand-dbcmd.dropUser)
* [`updateUser`](https://www.mongodb.com/docs/manual/reference/command/updateUser/#mongodb-dbcommand-dbcmd.updateUser)
* [`usersInfo`](https://www.mongodb.com/docs/manual/reference/command/usersInfo/#mongodb-dbcommand-dbcmd.usersInfo)

Custom roles support will be added later.

## Create a Function for Privilege Extraction For Commands

```
ResourcePrivilegesSet* getRequiredResourcePrivilegesSetForCmd(pgbson *bson_spec);
```

A function to a bson command, and return the ResourcePrivilegeSet required to execute the command. Not all commands can have have their privileges extracted like this, e.g. killOp where a user can kill their own operations, but needs the killAnyOp privilege to kill others, in those cases this function will indicate an error.

## Privilege Validation Functions

A low level function that given a resource privilege set for a user, and required resource privilege set, check if the user has all the required privileges. 

```
bool userHasPrivileges(const char *username, pgbson *bson_spec)
```

A helper functions for cases where the behaviour of the command depends on the users privileges, these need to be validated by the action (e.g. killOp)

```
bool userHasPrivileges(const char *username, ResourcePrivilegeSet* requiredPriv)
```

A matching UDF for the Gateway, if needed

```
CREATE OR REPLACE FUNCTION __API_SCHEMA_INTERNAL_V2__.rbacUserHasPrivileges(
    p_user_name text, requiredPriv __CORE_SCHEMA__.bson)
 RETURNS bool
 LANGUAGE C
 -- e.g.
 select docdb_internal.rbacUserHasPrivileges("user1", 
    [{db: "admin", collection: "killCursor", privileges: ["killAnyCursor"]}]
 )
```

## Add RBAC Validation in All Operations 

For every operation the gateway calls in the extension add a check for a privilege check for the current user. This will be behind a GUC that can be used to disable all RBAC for DocumentDB. For special cases, like killOp add specific logic.

## Caching / Optimization

A cache will be added to store user privileges, and will be added transparently inside the user validation functions. The goal is to avoid going to storage as much as possible. The cache design will be reviewed separately. 

## Testing 

All components will be validated by unit tests, and functional tests. The major components to focus tests on are:

* The privilege extraction functions
    * Construct many variations of each possible mongo command, and pass it to the `getRequiredResourcePrivilegeSetForCmd` function and assert the exact required privileges are returned
* End to end command validation
    * Construct many variations for each command, execute each once with a user without the required privileges, and one with a user with the required privileges

## Custom Roles

Custom roles will be added in the future, the existing roles and privilege extraction logic should support them, the main work will be adding customer commands for managing them, and adding validation.

# DocumentDb to Postgres Role Mapping

Postgres and DocumentDB both support role based authentication at a high level, but there are structural differences between the two that make it impossible to create a 1:1 mapping. 

A simple example of this is for the DocumentDb write privilege. A DocumentDB user can have the write privilege on any collection called items “items” anywhere in the database through a custom role: 

```
// Create the custom role with write privileges on catalog.items
db.createRole({
  role: "itemsWriter",
  privileges: [
    {
      resource: { db: "", collection: "items" },
      actions: ["insert", "update", "remove", "find"]
    }
  ],
  roles: []
})

// Grant the role to user1
db.grantRolesToUser("user1", ["itemsWriter"])
```

At this point the no databases or collections need to exist, but the user is able to gain these privileges on any table that exists in the future. By the way the “insert” operation works in DocumentDb the user also has privileges to create a collection names “items” in any database. These actions cannot be modeled by Postgres roles. 

There are also operational and diagnostic actions where Postgres does not provide the granularity needed to match the requirements for DocumentDb. 

## Proposed System

The proposed system is to have a two stage authorization model, where the top level DocumentDB API operations validate the full required privileges and also maintain Postgres roles and authorization for the critical privileges (insert, update, delete). 

DocumentDb will manage the Postgres privileges for it’s users, and map Postgres roles to ensure that the user always have the critical permissions, but will also allow the user to act beyond their Postgres privilege levels for actions that cannot be appropriately modeled. 

For the above example, if “user1” tries to do an insert into an “items” collection that does not exist, the DocumentDB API insert UDF would recognize that by the DocumentDB auth rules this is a valid operation, and assume higher level privileges to create the “items” collection for the user, and assign the user the correct Postgres privileges for the newly created collection. Any subsequent inserts to that collection would be authorized by Postgres based on it’s auth rules. 

## DocumentDB Roles

DocumentDB has 3 types of roles: 

* Static Built-in roles, these are standard built in roles, like “dbAdmin” with are associated with the “admin” database, there is only one version of each of these roles
* Dynamic Built-in roles, these are built in roles that are associated with a database, e.g. `{“db”:“test”, “role”: “write”}`. These provide built in privileges based on the named database where they are assigned. For each of these role definitions there is theoretically one per database the customer creates. 
* Custom Role, these are roles the customer creates, that are associated with the database the customer creates them in (but can have privileges outside that database), these can also inherit from other roles. 

To support all types of roles, we will only create roles in the DocumentDb roles table as roles are needed, e.g. built-in role used or custom role created. The definitions for built-in roles will live in the code.

## Mapped Mongo Actions to Postgres Grants

**Note:** This assumes we has transitioned to each DocumentDb database is corresponds to a Postgres schema.

The following “critical” MongoDb actions are mapped to Postgres roles, All other privileges will be enforced by the DocumentDb extension.

find → SELECT
insert → INSERT
remove → DELETE
update → UPDATE

These actions can be assigned at the database+collection level, the database, the cluster level, and associated with a collection name regardless of database. 

**Note**: We do not create a combined “write” role to maintain consistency between built-in and custom roles.

### Primitive Roles

The critical privileges will be represented in the database as “primitive roles”, these roles store the final privileges to associate Postgres actions with the underlying tables, we will keep a table mapping the logical primitive role, to it’s Postgres role. Primitive roles will be created on demand as they are needed by built-in or custom roles. When DocumentDb collections or databases are created/deleted/renamed the system will only update the grants on the primitive roles.

```
CREATE TABLE documentdb_api_catalog.primitive_roles (
    pg_role_name TEXT REFERENCES pg_roles(rolname) ON DELETE CASCADE,
    action varchar,
    database varchar,
    collection varchar,
    PRIMARY KEY (pg_role_name),
    UNIQUE (action, database, collection)
);
```

e.g.

|pg_role_name	|action	|database	|collection	|
|---	|---	|---	|---	|
|docdb_read_any_database	|find	|NULL	|NULL	|
|docdb_insert_any_database	|insert	|NULL	|NULL	|
|docdb_remove_any_database	|remove	|NULL	|NULL	|
|docdb_read_database_23	|find	|"db23"	|NULL	|
|docdb_read_database_23_coll_11	|find	|"db23"	|"coll11"	|
|docdb_read_any_database_coll_11	|find	|NULL	|"coll11"	|

##### Role Creation

When a primitive role is used for the first time:

1. A Postgres roles is created
2. A entry is made in the primitive_roles table
3. The collection metadata table is scanned to find every matching database / collection and grants are added to the newly created Postgres role.

**To grant roles**

* Primitive roles with a **database** = NULL and **collection** = NULL represent privileges on every database and collection within DocumentDb, we still want to limit this role to only schemas DocumentDb has created, so we will iterate over all schemas and grant privileges to that schema.
    * `For DB_SCHEMA in ALL DOC DB DATABASES:
            GRANT SELECT ON ALL TABLES IN SCHEMA **DB_SCHEMA** TO docdb_read_any_database`
* Primitive roles with a **database** is set and **collection** = NULL represent privileges on every and collection within that database, we will grant privileges to that schema.
    * `GRANT SELECT ON ALL TABLES IN SCHEMA `**`DB_SCHEMA`**` TO docdb_read_database_23`
* Primitive roles with **database** and **collection** set represent a privilege on a specific collection, and just that privilege is set.
    * `GRANT SELECT ON "DB_SCHEMA"."COLLECTION" TO docdb_read_database_23_coll_11`
* Primitive roles with **database** = NULL and **collection** is set represent privileges on any collection with that name:
    * `FOR `**`DB_SCHEMA`**` in ALL DOC DB DATABASE WITH A COLLECTION NAMED `**`COLL_NAME`**`:
            GRANT SELECT ON "`**`DB_SCHEMA`**`"."`**`COLL_NAME`**`" TO docdb_read_database_23_coll_11`

##### Role Updates

As DocumentDB roles are based on names, and Postgres creates grants based on objects we need to continuously update the primitive grants as collections and databases are created/updated/deleted. To track this we will use triggers on the collection metadata table. 

ON INSERT:
This is a new collection, and potentially a new database 

    1. If its a new database find any role that applies to either all databases, or a database with that name, and apply the grant at the schema level .
    2. Find any primitive role that matches the collection name, and apply the grant

ON UPDATE:
Update are treated as rename operations, since Postgres tracks permission by objects we need to revoke the grant to the primitive role associated with the old collection name, for the new collection 

    1. If the database of collection has changed, revoke privileges from any roles based on the old collection name
    2. If its a new database find any role that applies to either all databases, or a database with that name, and apply the grant at the schema level .
    3. Find any primitive role that matches the collection name, and apply the grant

ON DELETE:
A delete should correspond to deleting a resource, where Postgres would automatically revoke any grants, so no action is needed. There is a potential issue if a rename is implemented as a delete and in insert into the collection metadata table, in that case the trigger would not be able to correctly revoke privileges on the old primitive roles. 

We could implement revokes if the old collection still exists, but in the event of a rename + delete + insert the trigger would not be able to identify the old table to issue the revoke. 

### Built In Roles

Built in roles are created as needed, when they are granted to a user, if the roles does not exist the definition is loaded from a hardcoded version (or a template table?), and a Postgres role is created. Then any primitive roles are created, and granted privileges, then Postgres user is granted the new Postgres role, along with the role being assigned to the user in the DocumentDb users table.

#### Example:

A DocumentDb user is granted the “readAnyDatabase” built-in role, which has the definition:

```
{
  "role": "readWriteAnyDatabase",
  "database": "admin",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": [
        "find", "insert", "update", "remove",
        "createCollection", "dropCollection",
        "createIndex", "dropIndex",
        "collMod", "collStats", "dbStats",
        "listCollections", "listIndexes"
      ]
    }
  ]
}
```

1. System checks for an existing role:“dbAdmin” db:“admin” role, and does not find it in the DocumentDb roles
2. System creates a Postgres role: “docdb_admin_dbadmin”
3. System creates an entry in the DocumentDb roles table for the dbAdmin role, referencing the new Postgres role name
4. System identifies the new role has the following privileges that correspond to primitive roles:
    1. {"db": "", "collection": ""}: find
        {"db": "", "collection": ""}: insert
        {"db": "", "collection": ""}: update
        {"db": "", "collection": ""}: remove
5. System checks if the primitive roles exist, they do not
6. System creates the primitive roles, and grants them the correct privileges for the existing collections / databases
7. System grants the Postgres role representing the primitive roles to the new Postgres role for readAnyDatabase

```
GRANT docdb_any_db_any_collection_find TO docdb_admin_readWriteAnyDatabase;
GRANT docdb_any_db_any_collection_insert TO docdb_admin_readWriteAnyDatabase;
GRANT docdb_any_db_any_collection_update TO docdb_admin_readWriteAnyDatabase;
GRANT docdb_any_db_any_collection_remove TO docdb_admin_readWriteAnyDatabase;
```

### Custom Roles

Custom roles will follow the exact same pattern as built-in roles, as they role entry is created on demand, and any dependencies are also created, the additional options with custom roles is the ability to have them inherit from other DocumentDb roles. 

Inheriting roles will be implemented using Postgres’ inheritance, by granting dependent role to the new role. When deleting a role the system will first look for any DocumentDb roles that inherit from it, remove it from the DocumentDb roles document, and then revoking the role from the one that depends on it.

# OSSDocDB RBAC - Per Command Breakdown

## Requirements

* All DocumentDb tables exist within DocumentDB specific Postgres schemas, that we can identify at runtime. 
* All DocumentDb Postgres users are given a token role to identify them, the **DocumentDbUser** role.
* A DocumentDB service admin role exists with high level privileges, called **DocumentDbServiceAdmin**, operations that require higher level privileges can be executed as the **DocumentDbServiceAdmin**, either through a UDF configured with a security definer, or by the UDF code directly switching the user internally (through C function).

## Spec

DocumentDb privileges are enforced through a combination of traditional Postgres roles, and custom authentication at the object access level setup by the extension. The extension adds extra authorization requirements to commands operate within a DocumentDb schema, that are being run by users that have the **DocumentDbUser** role. Actions by any other user will only be authorized by traditional Postgres roles.

DocumentDb roles, assigned to users are modeled as Postgres roles attached to the user which have a corresponding entry in an internal role table mapping the role to the DocumentDb privilege actions. In cases where the available Postgres privileges are less granular than the DocumentDb equivalent, the Postgres role may allow for more privileges and the extension will enforce the scoped down privilege.

DocumentDb metadata tables use row level access control to limit what values the **DocumentDbUser** can see (e.g. limit what collections can be seen when running $listCollections), but can only be written to through a UDF which uses the **DocumentDbServiceAdmin** role. This is done to ensure a **DocumentDbUser** cannot corrupt any metadata in the database.


### Select / Insert / Delete Privileges 

In the initial design, standard Postgres privileges are used to gate the users access to select, insert, and delete within the DocumentDb database. Whenever a table is created the extension must lookup any DocumentDb roles that should have access to the new collection, and do a grant. 

An alternative option is to give the **DocumentDbUser** role full privileges on all the collection in the DocumentDb schemas, and have a lower level object access hook validate access to the tables based only on the DocumentDb privileges. (see: https://github.com/postgres/postgres/blob/master/contrib/sepgsql/hooks.c). This could be used to enforce access through name matching, rather than per-table grants.


## Metadata Table Access

There are 4 tables of metadata that map data between Postgres structors and DocumentDB concepts, these tables are: 

* collections
* collection_indexes
* users
* roles

For **DocumentDbUser** users, these tables will have row level privileges, which check which rows can be seen based on the associated DocumentDB permissions. All **DocumentDbUser** users will have the Postgres read privilege for these tables, but some of the data can be limited by row level controls. The row level controls will not apply to other Postgres users.

The **DocumentDbUser** does not have write access to these collections. All writes will be done by docdb_api.* operations, that operate as **DocumentDbServiceAdmin**, this is done to ensure a user cannot corrupt the metadata.

### collections

To read a row, the Postgres user must have either the `listCollection` privilege for that collection or database, or have read access to that collection.


### collection_indexes

To read a row the user must have the `listIndexes` privilege, or read privileges on the collection associated with the index.

### users

To read a row the **DocumentDbUser** must have the `viewUser` privilege or, the row is for their own user.

### roles

To read a row the **DocumentDbUser** must have the `viewRole` privilege, or have been granted the role.

## Enforcing Consistent Visibility For A Collection That Doesn’t Exist

When doing a read operation on a collection MongoDB properly checks the required authorization based in the collection name, and will return an error even if the collection does not exist. This prevents a user without access from being able to determine if there is a collection.

The extension code that deals with nonexistent tables will need to be aware of these rules when returning results.

## Per-Command Break Down

[`aggregate`](https://www.mongodb.com/docs/manual/reference/command/aggregate/#mongodb-dbcommand-dbcmd.aggregate)

* Aggregate command is a combination of stages, that usually act on data loaded from a collection, these can be handled by the standard Postgres read privilege.
* A few of the stages require special handling, such as $listCollections, these stages are also represented as commands below, and the UDF that generates some of the data may need to be run as **DocumentDbServiceAdmin**
* $lookup allows for a join, which is also a table read, which can be processed by standard Postgres read privilege
* $out allows writing to a collection, and will be processed as a collection creation, to be run as **DocumentDbServiceAdmin**

[`count`](https://www.mongodb.com/docs/manual/reference/command/count/#mongodb-dbcommand-dbcmd.count)

* Count is deprecated command, modern drivers handle this with an aggregate, the count command still exists. This command runs on a collection and requires the `read` privilege, which can be verified by Postgres.

[`distinct`](https://www.mongodb.com/docs/manual/reference/command/distinct/#mongodb-dbcommand-dbcmd.distinct)

* Distinct runs on a collection and requires the `read` privilege, which can be verified by Postgres.

[`bulkWrite`](https://www.mongodb.com/docs/manual/reference/command/bulkWrite/#mongodb-dbcommand-dbcmd.bulkWrite)

* A combination of insert/update/delete operations, all can be handed by Postgres privileges, except implicit collection creation, see `create`

[`delete`](https://www.mongodb.com/docs/manual/reference/command/delete/#mongodb-dbcommand-dbcmd.delete)

* Delete on a single collection, can be handed by Postgres privileges

[`find`](https://www.mongodb.com/docs/manual/reference/command/find/#mongodb-dbcommand-dbcmd.find)

* Find on a single collection, can be handed by Postgres privileges.

[`findAndModify`](https://www.mongodb.com/docs/manual/reference/command/findAndModify/#mongodb-dbcommand-dbcmd.findAndModify)

* Find and overwrite on a single collection, can be handed by Postgres privileges, except implicit collection creation, see `create`

[`insert`](https://www.mongodb.com/docs/manual/reference/command/insert/#mongodb-dbcommand-dbcmd.insert)

* Inserts a new document it a collection, can be handed by Postgres privileges, except implicit collection creation, see `create`

[`update`](https://www.mongodb.com/docs/manual/reference/command/update/#mongodb-dbcommand-dbcmd.update)

* Updates a new document it a collection, can be handed by Postgres privileges, except implicit collection creation, see `create`

Query Plan Cache Commands ([`planCacheClear`](https://www.mongodb.com/docs/manual/reference/command/planCacheClear/#mongodb-dbcommand-dbcmd.planCacheClear), [`planCacheClearFilters`](https://www.mongodb.com/docs/manual/reference/command/planCacheClearFilters/#mongodb-dbcommand-dbcmd.planCacheClearFilters), [`planCacheListFilters`](https://www.mongodb.com/docs/manual/reference/command/planCacheListFilters/#mongodb-dbcommand-dbcmd.planCacheListFilters), [`planCacheSetFilter`](https://www.mongodb.com/docs/manual/reference/command/planCacheSetFilter/#mongodb-dbcommand-dbcmd.planCacheSetFilter))

* N/A

Authentication Commands ([`authenticate`](https://www.mongodb.com/docs/manual/reference/command/authenticate/#mongodb-dbcommand-dbcmd.authenticate), [`logout`](https://www.mongodb.com/docs/manual/reference/command/logout/#mongodb-dbcommand-dbcmd.logout))

* N/A

User Management Commands - Write Commands ([`createUser`](https://www.mongodb.com/docs/manual/reference/command/createUser/#mongodb-dbcommand-dbcmd.createUser), [`dropAllUsersFromDatabase`](https://www.mongodb.com/docs/manual/reference/command/dropAllUsersFromDatabase/#mongodb-dbcommand-dbcmd.dropAllUsersFromDatabase), [`dropUser`](https://www.mongodb.com/docs/manual/reference/command/dropUser/#mongodb-dbcommand-dbcmd.dropUser), [`grantRolesToUser`](https://www.mongodb.com/docs/manual/reference/command/grantRolesToUser/#mongodb-dbcommand-dbcmd.grantRolesToUser), [`revokeRolesFromUser`](https://www.mongodb.com/docs/manual/reference/command/revokeRolesFromUser/#mongodb-dbcommand-dbcmd.revokeRolesFromUser), [`updateUser`](https://www.mongodb.com/docs/manual/reference/command/updateUser/#mongodb-dbcommand-dbcmd.updateUser))

* These commands need to be run through docdb_api.* operations, and are validated in the method, then executed as **DocumentDbServiceAdmin**. These operations need to manipulate Postgres roles, and DocumentDB metadata tables.
* The createUser command always adds the **DocumentDbUser** role to the newly created user
* All the user modification commands only work on users with the **DocumentDbUser** role.

[`usersInfo`](https://www.mongodb.com/docs/manual/reference/command/usersInfo/#mongodb-dbcommand-dbcmd.usersInfo)

* This can be made up from information in the docdb_users and docdb_roles table that the user has access to. 

Role Management Commands - Write Commands ([`createRole`](https://www.mongodb.com/docs/manual/reference/command/createRole/#mongodb-dbcommand-dbcmd.createRole), [`dropRole`](https://www.mongodb.com/docs/manual/reference/command/dropRole/#mongodb-dbcommand-dbcmd.dropRole), [`dropAllRolesFromDatabase`](https://www.mongodb.com/docs/manual/reference/command/dropAllRolesFromDatabase/#mongodb-dbcommand-dbcmd.dropAllRolesFromDatabase), [`grantPrivilegesToRole`](https://www.mongodb.com/docs/manual/reference/command/grantPrivilegesToRole/#mongodb-dbcommand-dbcmd.grantPrivilegesToRole), [`grantRolesToRole`](https://www.mongodb.com/docs/manual/reference/command/grantRolesToRole/#mongodb-dbcommand-dbcmd.grantRolesToRole), [`invalidateUserCache`](https://www.mongodb.com/docs/manual/reference/command/invalidateUserCache/#mongodb-dbcommand-dbcmd.invalidateUserCache), [`revokePrivilegesFromRole`](https://www.mongodb.com/docs/manual/reference/command/revokePrivilegesFromRole/#mongodb-dbcommand-dbcmd.revokePrivilegesFromRole), [`revokeRolesFromRole`](https://www.mongodb.com/docs/manual/reference/command/revokeRolesFromRole/#mongodb-dbcommand-dbcmd.revokeRolesFromRole), [`updateRole`](https://www.mongodb.com/docs/manual/reference/command/updateRole/#mongodb-dbcommand-dbcmd.updateRole))

* These commands need to be run through docdb_api.* operations, and are validated in the method, then executed as **DocumentDbServiceAdmin**. These operations need to manipulate Postgres roles, and DocumentDB metadata tables

[`rolesInfo`](https://www.mongodb.com/docs/manual/reference/command/rolesInfo/#mongodb-dbcommand-dbcmd.rolesInfo)

* This can be made up from information in the docdb_users and docdb_roles table that the user has access to. 

[`abortTransaction`](https://www.mongodb.com/docs/manual/reference/command/abortTransaction/#mongodb-dbcommand-dbcmd.abortTransaction)

* Can only be run within a users session.

[`commitTransaction`](https://www.mongodb.com/docs/manual/reference/command/commitTransaction/#mongodb-dbcommand-dbcmd.commitTransaction)

* Can only be run within a users session.

[`endSessions`](https://www.mongodb.com/docs/manual/reference/command/endSessions/#mongodb-dbcommand-dbcmd.endSessions)

* End session can only end sessions associated with the user. This can be implemented as a user killing their own commands

[`killAllSessions`](https://www.mongodb.com/docs/manual/reference/command/killAllSessions/#mongodb-dbcommand-dbcmd.killAllSessions) / [`killAllSessionsByPattern`](https://www.mongodb.com/docs/manual/reference/command/killAllSessionsByPattern/#mongodb-dbcommand-dbcmd.killAllSessionsByPattern) / [`killSessions`](https://www.mongodb.com/docs/manual/reference/command/killSessions/#mongodb-dbcommand-dbcmd.killSessions)

* Users must have the `killAnySession` privilege to kill other user’s sessions. These operations will be implemented by docdb_api.* operation to verify privileges, and use the **DocumentDbServiceAdmin** role to kill operations owned by other users (limited to users with the **DocumentDbUser** role).

[`refreshSessions`](https://www.mongodb.com/docs/manual/reference/command/refreshSessions/#mongodb-dbcommand-dbcmd.refreshSessions) / [`startSession`](https://www.mongodb.com/docs/manual/reference/command/startSession/#mongodb-dbcommand-dbcmd.startSession)

* These commands are local to a user, and don’t have any Postgres equivalent

[`collMod`](https://www.mongodb.com/docs/manual/reference/command/collMod/#mongodb-dbcommand-dbcmd.collMod)

* CollMod does a number of different things and required privileges depend on the action. For modifying non-capped collections it requires the `collMod` privilege, for views it also required `find` on the source view.
* Since CollMod can modify indexes and the metadata it will be run as the **DocumentDbServiceAdmin** role.

[`compact`](https://www.mongodb.com/docs/manual/reference/command/compact/#mongodb-dbcommand-dbcmd.compact) 

* Compact uses a VACUUM FULL operation, this can only be done a Postgres super user, or the table owner. This will need to be run as **DocumentDbServiceAdmin**

[`create`](https://www.mongodb.com/docs/manual/reference/command/create/#mongodb-dbcommand-dbcmd.create)

* Create needs to create tables and write metadata, it will be run as the **DocumentDbServiceAdmin** role. The **DocumentDbUser** user does not get create table privileges, to prevent them from being able to create unused tables throughout the database, this ensures the metadata is always set correctly.

[`createIndexes`](https://www.mongodb.com/docs/manual/reference/command/createIndexes/#mongodb-dbcommand-dbcmd.createIndexes)

* createIndexes is run as the **DocumentDbServiceAdmin** role, it needs to populate the collection_indexes table.

[`currentOp`](https://www.mongodb.com/docs/manual/reference/command/currentOp/#mongodb-dbcommand-dbcmd.currentOp)

* Current Op merges data from pg_stat_activity and a DocumentDb in memory store. A user with the DocumentDb `inprog` privilege can see all running queries, if not they can only see their own.
* A user with the **DocumentDbUser** role will be able to see their data in pg_stat_activity. When the docdb_api.currentOp is called, if the user specifies `$ownOps` the command will run as the **DocumentDbUser**. If the command runs with `$all` the command will run as the **DocumentDbServiceAdmin** role.

[`drop`](https://www.mongodb.com/docs/manual/reference/command/drop/#mongodb-dbcommand-dbcmd.drop)

* Drop deletes a collection. This could be implemented with Postgres privileges, and leaving triggers to remove table / index metadata when the collection is dropped. Or it could be run as the **DocumentDbServiceAdmin** role.

[`dropDatabase`](https://www.mongodb.com/docs/manual/reference/command/dropDatabase/#mongodb-dbcommand-dbcmd.dropDatabase)

* Drop database deletes all collections in a database (Schema in Postgres). This could be implemented with Postgres privileges, and leaving triggers to remove table / index metadata when the collection is dropped. Or it could be run as the **DocumentDbServiceAdmin** role

[`dropConnections`](https://www.mongodb.com/docs/manual/reference/command/dropConnections/#mongodb-dbcommand-dbcmd.dropConnections)

* Currently not implemented
* Drop connections requires the `dropConnections` privilege. This potentially needs to be implemented in the Gateway along with the extension? for killing Postgres backends it will need to be run as the **DocumentDbServiceAdmin** role.

[`dropIndexes`](https://www.mongodb.com/docs/manual/reference/command/dropIndexes/#mongodb-dbcommand-dbcmd.dropIndexes)

* Drop deletes an index. This could be implemented with Postgres privileges, and leaving triggers to remove index metadata when the collection is dropped. Or it could be run as the **DocumentDbServiceAdmin** role.

[`getParameter`](https://www.mongodb.com/docs/manual/reference/command/getParameter/#mongodb-dbcommand-dbcmd.getParameter)

* DocumentDB users need the `getParameter` privilege to see the parameters. In Postgres most of the parameters are likely to be stored as GUC’s, which are split between only Super user visible and visible for everyone. To support this we would make the GUC’s only super user visible, and then read them as the **DocumentDbServiceAdmin** role. 

[`killCursors`](https://www.mongodb.com/docs/manual/reference/command/killCursors/#mongodb-dbcommand-dbcmd.killCursors)

* This will likely need to kill Postgres backends, a user can kill their own backends, but if they have the DocumentDB `killAnyCursor` the command will need to execute as the **DocumentDbServiceAdmin** role.

[`killOp`](https://www.mongodb.com/docs/manual/reference/command/killOp/#mongodb-dbcommand-dbcmd.killOp)

* This command will kill Postgres backends, a user can kill their own backends, but if they have the DocumentDB `killOp` privilege the command will need to execute as the **DocumentDbServiceAdmin** role.

[`listCollections`](https://www.mongodb.com/docs/manual/reference/command/listCollections/#mongodb-dbcommand-dbcmd.listCollections) / [`listDatabases`](https://www.mongodb.com/docs/manual/reference/command/listDatabases/#mongodb-dbcommand-dbcmd.listDatabases) / [`listIndexes`](https://www.mongodb.com/docs/manual/reference/command/listIndexes/#mongodb-dbcommand-dbcmd.listIndexes)

* These command reads data from the metadata tables, the command can be executed as the **DocumentDbUser**.

[`reIndex`](https://www.mongodb.com/docs/manual/reference/command/reIndex/#mongodb-dbcommand-dbcmd.reIndex)

* Deprecated in MongoDb, it requires a drop index and create index in MongoDb, it requires the `reIndex` privilege. Internally it is a `REINDEX INDEX CONCURRENTLY` command. This can be run by Postgres users with the `MAINTAIN` role for the table, but that also provides additional access, this command should be run as the **DocumentDbServiceAdmin** role.

[`renameCollection`](https://www.mongodb.com/docs/manual/reference/command/renameCollection/#mongodb-dbcommand-dbcmd.renameCollection)

* This needs to modify metadata, this command should be run as the **DocumentDbServiceAdmin** role.

[`collStats`](https://www.mongodb.com/docs/manual/reference/command/collStats/#mongodb-dbcommand-dbcmd.collStats)

* CollStats (deprecated, and replaced with the aggregation stage $collStats), reads metadata from several pg_* tables to fill in the data, some of this data is only accessible to users that have privileges to read the tables. A DocumentDB user can access collStats without the read privilege. This command should be run as the **DocumentDbServiceAdmin** role.

[`connectionStatus`](https://www.mongodb.com/docs/manual/reference/command/connectionStatus/#mongodb-dbcommand-dbcmd.connectionStatus)

* Returns stats about a users connection, it only needs accessible metadata for the user. The command can be executed as the **DocumentDbUser**.

[`dataSize`](https://www.mongodb.com/docs/manual/reference/command/dataSize/#mongodb-dbcommand-dbcmd.dataSize)

* This command runs on a collection and requires the `read` privilege, which can be verified by Postgres.

[`dbHash`](https://www.mongodb.com/docs/manual/reference/command/dbHash/#mongodb-dbcommand-dbcmd.dbHash)

* This hashes the data of all collections in a Db, this command needs the `dbHash` privilege to execute the command. It can be run without the `find` privilege. This command should be run as the **DocumentDbServiceAdmin** role.

[`dbStats`](https://www.mongodb.com/docs/manual/reference/command/dbStats/#mongodb-dbcommand-dbcmd.dbStats)

* dbStats reads metadata from several pg_* tables to fill in the data, some of this data is only accessible to users that have privileges to read the tables. A DocumentDB user can access dbStats without the read privilege. This command should be run as the **DocumentDbServiceAdmin** role.

[`explain`](https://www.mongodb.com/docs/manual/reference/command/explain/#mongodb-dbcommand-dbcmd.explain)

* Explain requires the privileges of the underlying query.

[`getCmdLineOpts`](https://www.mongodb.com/docs/manual/reference/command/getCmdLineOpts/#mongodb-dbcommand-dbcmd.getCmdLineOpts)

* Does not require privileges

[`getLog`](https://www.mongodb.com/docs/manual/reference/command/getLog/#mongodb-dbcommand-dbcmd.getLog)

* Requires the `getLog` privilege, this would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`hostInfo`](https://www.mongodb.com/docs/manual/reference/command/hostInfo/#mongodb-dbcommand-dbcmd.hostInfo)

* Requires the `hostInfo` privilege, this would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`listCommands`](https://www.mongodb.com/docs/manual/reference/command/listCommands/#mongodb-dbcommand-dbcmd.listCommands)

* No Auth Required

[`ping`](https://www.mongodb.com/docs/manual/reference/command/ping/#mongodb-dbcommand-dbcmd.ping)

* No auth required

[`profile`](https://www.mongodb.com/docs/manual/reference/command/profile/#mongodb-dbcommand-dbcmd.profile)

* Requires the `enableProfiler` privilege. This would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`serverStatus`](https://www.mongodb.com/docs/manual/reference/command/serverStatus/#mongodb-dbcommand-dbcmd.serverStatus)

* Requires the `serverStatus` privilege. This would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`whatsmyuri`](https://www.mongodb.com/docs/manual/reference/command/whatsmyuri/#mongodb-dbcommand-dbcmd.whatsmyuri)

* Does not require authorization

[`getAuditConfig`](https://www.mongodb.com/docs/manual/reference/command/getAuditConfig/#mongodb-dbcommand-dbcmd.getAuditConfig)

* Requires the `auditRead` privilege. This would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`logApplicationMessage`](https://www.mongodb.com/docs/manual/reference/command/logApplicationMessage/#mongodb-dbcommand-dbcmd.logApplicationMessage)

* Requires the `applicationMessage` privilege. This would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`setAuditConfig`](https://www.mongodb.com/docs/manual/reference/command/setAuditConfig/#mongodb-dbcommand-dbcmd.setAuditConfig)

* Requires the `auditWrite` privilege. This would only be available through a docdb_api.* operation, it will need to access data not accessible to the users, if that data is stored in a Postgres table the command will need to be run as the **DocumentDbServiceAdmin** role.

[`createSearchIndexes`](https://www.mongodb.com/docs/manual/reference/command/createSearchIndexes/#mongodb-dbcommand-dbcmd.createSearchIndexes) / [`dropSearchIndex`](https://www.mongodb.com/docs/manual/reference/command/dropSearchIndex/#mongodb-dbcommand-dbcmd.dropSearchIndex) / [`updateSearchIndex`](https://www.mongodb.com/docs/manual/reference/command/updateSearchIndex/#mongodb-dbcommand-dbcmd.updateSearchIndex)

* These need the `createSearchIndex` privilege, these are Atlas only

## Appendix: Unsupported Operations

[`cloneCollectionAsCapped`](https://www.mongodb.com/docs/manual/reference/command/cloneCollectionAsCapped/#mongodb-dbcommand-dbcmd.cloneCollectionAsCapped)
[`compactStructuredEncryptionData`](https://www.mongodb.com/docs/manual/reference/command/compactStructuredEncryptionData/#mongodb-dbcommand-dbcmd.compactStructuredEncryptionData)
[`convertToCapped`](https://www.mongodb.com/docs/manual/reference/command/convertToCapped/#mongodb-dbcommand-dbcmd.convertToCapped)
[`logRotate`](https://www.mongodb.com/docs/manual/reference/command/logRotate/#mongodb-dbcommand-dbcmd.logRotate)
[`filemd5`](https://www.mongodb.com/docs/manual/reference/command/filemd5/#mongodb-dbcommand-dbcmd.filemd5)
[`fsync`](https://www.mongodb.com/docs/manual/reference/command/fsync/#mongodb-dbcommand-dbcmd.fsync)
[`fsyncUnlock`](https://www.mongodb.com/docs/manual/reference/command/fsyncUnlock/#mongodb-dbcommand-dbcmd.fsyncUnlock)
[`getDefaultRWConcern`](https://www.mongodb.com/docs/manual/reference/command/getDefaultRWConcern/#mongodb-dbcommand-dbcmd.getDefaultRWConcern)

[`getClusterParameter`](https://www.mongodb.com/docs/manual/reference/command/getClusterParameter/#mongodb-dbcommand-dbcmd.getClusterParameter)

* DocumentDB users need the `getClusterParameter` privilege to see the parameters. In Postgres most of the parameters are likely to be stored as GUC’s, which are split between only Super user visible and visible for everyone. To support this we would make the GUC’s only super user visible, and then read them as the **DocumentDbServiceAdmin** role. 

[`rotateCertificates`](https://www.mongodb.com/docs/manual/reference/command/rotateCertificates/#mongodb-dbcommand-dbcmd.rotateCertificates)
[`setFeatureCompatibilityVersion`](https://www.mongodb.com/docs/manual/reference/command/setFeatureCompatibilityVersion/#mongodb-dbcommand-dbcmd.setFeatureCompatibilityVersion)
[`setIndexCommitQuorum`](https://www.mongodb.com/docs/manual/reference/command/setIndexCommitQuorum/#mongodb-dbcommand-dbcmd.setIndexCommitQuorum)
[`setClusterParameter`](https://www.mongodb.com/docs/manual/reference/command/setClusterParameter/#mongodb-dbcommand-dbcmd.setClusterParameter)
[`setParameter`](https://www.mongodb.com/docs/manual/reference/command/setParameter/#mongodb-dbcommand-dbcmd.setParameter)
[`setDefaultRWConcern`](https://www.mongodb.com/docs/manual/reference/command/setDefaultRWConcern/#mongodb-dbcommand-dbcmd.setDefaultRWConcern)
[`setUserWriteBlockMode`](https://www.mongodb.com/docs/manual/reference/command/setUserWriteBlockMode/#mongodb-dbcommand-dbcmd.setUserWriteBlockMode)
[`shutdown`](https://www.mongodb.com/docs/manual/reference/command/shutdown/#mongodb-dbcommand-dbcmd.shutdown)
[`validateDBMetadata`](https://www.mongodb.com/docs/manual/reference/command/validateDBMetadata/#mongodb-dbcommand-dbcmd.validateDBMetadata)

[Replication Commands](https://www.mongodb.com/docs/manual/reference/command/#replication-commands) (13 commands)
[Sharding Commands](https://www.mongodb.com/docs/manual/reference/command/#sharding-commands) (50 commands)

[`connPoolStats`](https://www.mongodb.com/docs/manual/reference/command/connPoolStats/#mongodb-dbcommand-dbcmd.connPoolStats)
[`shardConnPoolStats`](https://www.mongodb.com/docs/manual/reference/command/shardConnPoolStats/#mongodb-dbcommand-dbcmd.shardConnPoolStats)
[`lockInfo`](https://www.mongodb.com/docs/manual/reference/command/lockInfo/#mongodb-dbcommand-dbcmd.lockInfo)
[`top`](https://www.mongodb.com/docs/manual/reference/command/top/#mongodb-dbcommand-dbcmd.top)
[`validate`](https://www.mongodb.com/docs/manual/reference/command/validate/#mongodb-dbcommand-dbcmd.validate)
[`mapReduce`](https://www.mongodb.com/docs/manual/reference/command/mapReduce/#mongodb-dbcommand-dbcmd.mapReduce)

