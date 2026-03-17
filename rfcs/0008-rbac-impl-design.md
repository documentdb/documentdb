# DocumentDB RBAC Implementation Overview

## Code Placement

As described in the RFC we are planning on doing the validation in the DocumentDb extension, leaving the Gateway as a pass through. We’ve discussed 3 possible locations where the RBAC code could be implemented and used within the DocumentDB extension. 

* RBAC is implemented into the separate Postgres extension the 
* Core logic is extracted into a separate C library
* All code in the main DocumentDB code base

At present AWS DocumentDb does not plan integrate the new RBAC components implemented for open source into our existing product,  we don’t see a need to extract it into extendable components. We plan to implement the logic in the main DocumentDB code base.

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
    ON documentdb_api_catalog.users(roles); 
```

Sample Entry:

```
| **user_name** | **user_data**
| admin     | {roles: [{"test":"write"}, {"admin":"readAnyDatabase"}]}
```

The users table references the Postgres role associated with the user, and stores the relevant user data in a bson object. The user_data object will store the roles associated with the user in a list of database/role name pairs (e.g. `roles``:`` ``[{``"test"``:``"write"``},`` ``{``"admin"``:``"readAnyDatabase"``}]`). Additional fields associated with the user can be added in the future, such as custom data, command, authenticationRestrictions (see: https://www.mongodb.com/docs/manual/reference/command/usersInfo/#output)

### Roles Table

```
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.roles (
    document documentdb_core.bson NOT NULL
);

-- Index for role lookup
CREATE INDEX IF NOT EXISTS idx_roles
    ON documentdb_api_catalog.users(database, rolename); 
    
-- Index for role inheritance lookup
CREATE INDEX IF NOT EXISTS idx_roles_parents
    ON documentdb_api_catalog.users(roles); 
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
}'
```

Built in roles that are scoped to a database, such as “read”, are stored with an empty string for a database, as well as for the database in the resources for privileges. When loading loading a role with an empty string for the “database” we load the privileges for the role scoped to the database the role was loaded in. 

```
{
  "role": "read"
  "database": "", // indicates the role is scoped to the db is was attached to
  "is_builtin": true,
  "description": "Provides read-only access to all collections",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": ["find"]
    }
  ],
  "roles": []
}
```

Built in roles are written to the table as part of the install SQL files.

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

### PrivilegeActionSet (Bitmap)

Bitmap for storing and comparing privileges on any action

```
#define PRIVILEGE_SET_SIZE ((PRIV_MAX + 31) / 32)

typedef struct PrivilegeSet {
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

### Resource Privilege

```
typedef struct ResourcePrivilege {
    Resource resource;
    PrivilegeSet privileges;
} ResourcePrivilege;
```

### Resource Privilege Set

```
typedef struct ResourcePrivilegeSet {
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

ResourcePrivilegeSet* getResourcePrivilegeSetForRoles(pgbson *roles_bson);

ResourcePrivilegeSet* getResourcePrivilegeSetForUser(const char *username);
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
ResourcePrivilegeSet* getRequiredResourcePrivilegeSetForCmd(pgbson *bson_spec);
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

