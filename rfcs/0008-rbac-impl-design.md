# DocumentDB RBAC Implementation Overview

## Code Placement

As described in the RFC we are planning on doing the validation in the DocumentDb extension, leaving the Gateway as a pass through. We’ve discussed 3 possible locations where the RBAC code could be implemented and used within the DocumentDB extension. 

* RBAC is implemented into a separate Postgres extension
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
    ON documentdb_api_catalog.users(user_data.roles); 
```

Sample Entry:

```
| **user_name** | **user_data**
| admin         | {
                    "roles": [
                        {"db":"test","role":"write"}, 
                        {"db":"admin", "role":"readAnyDatabase"}
                    ],
                    "comment": "..."
                  }
```

The users table references the Postgres role associated with the user, and stores the relevant user data in a bson object. The user_data object will store the roles associated with the user in a list of database/role name pairs (e.g. `roles: [{"db":"test", "role":"write"}, {"db":"admin", "role":"readAnyDatabase"}]`). Additional fields associated with the user can be added in the future, such as custom data, command, authenticationRestrictions (see: https://www.mongodb.com/docs/manual/reference/command/usersInfo/#output)

### Roles Table

```
CREATE TABLE IF NOT EXISTS documentdb_api_catalog.roles (
    role_document documentdb_core.bson NOT NULL
);

-- Index for role lookup
CREATE INDEX IF NOT EXISTS idx_roles
    ON documentdb_api_catalog.roles(role_document.database, role_document.role); 
    
-- Index for role inheritance lookup
CREATE INDEX IF NOT EXISTS idx_roles_parents
    ON documentdb_api_catalog.roless(role_document.roles); 
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
  "role": "read",
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

## In Memory Structs

We will create the following constants and in memory structs.

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
    char role[MAX_ROLE_NAME_LEN];
} Role;
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

# DocumentDb → Postgres Role Mapping

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

## 1:1 Role Mapping

Implementing a 1:1 roles mapping would have each role in the roles table table above be linked to an associated Postgres role, with dynamic built-in roles being created and deleted on demand, these roles would be given the critical privileges for every existing table that matches their privileges. When we assign a role to a user in DocumentDB the associated role will be granted to their Postgres user.

A mechanism (trigger?) would be used to react to table changes to update the Postgres privileges on:

* Table creation
* Table deletion
* Table rename

### Potential Issues

A split auth model can always have potential issues with the data being out of sync, or hard to understand as it’s in more than one place. Potential issues that can arise here:

* Through the DocumentDB APIs a user can take more actions than what is visible reviewing their Postgres privileges
* What doers a Postgres Admin modifying the privileges within a role mean
* What does a Postgres Admin deleting a built-in role mean



