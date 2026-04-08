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

