-- 002_builtin_roles.sql
-- Built-in Role Definitions
-- Populates the roles table with standard DocumentDB built-in roles

-- Built-in Role: readWrite
-- Provides read and write access to all collections in any database
INSERT INTO documentdb_api_catalog.roles (document)
SELECT documentdb_core.bson_from_json('
{
  "_id": {"$oid": "6587f191e810c19729de8601"},
  "role": "readWrite",
  "is_builtin": true,
  "description": "Provides read and write access to all collections",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": ["find", "insert", "update", "remove"]
    }
  ],
  "roles": []
}')
WHERE NOT EXISTS (
    SELECT 1 FROM documentdb_api_catalog.roles 
    WHERE document->>'role' = 'readWrite'
);

-- Built-in Role: read
-- Provides read-only access to all collections in any database
INSERT INTO documentdb_api_catalog.roles (document)
SELECT documentdb_core.bson_from_json('
{
  "_id": {"$oid": "6587f191e810c19729de8602"},
  "role": "read",
  "is_builtin": true,
  "description": "Provides read-only access to all collections",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": ["find"]
    }
  ],
  "roles": []
}')
WHERE NOT EXISTS (
    SELECT 1 FROM documentdb_api_catalog.roles 
    WHERE document->>'role' = 'read'
);

-- Built-in Role: dbAdmin
-- Provides database administration privileges
INSERT INTO documentdb_api_catalog.roles (document)
SELECT documentdb_core.bson_from_json('
{
  "_id": {"$oid": "6587f191e810c19729de8603"},
  "role": "dbAdmin",
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
}')
WHERE NOT EXISTS (
    SELECT 1 FROM documentdb_api_catalog.roles 
    WHERE document->>'role' = 'dbAdmin'
);

-- Built-in Role: userAdmin
-- Provides user and role administration privileges
INSERT INTO documentdb_api_catalog.roles (document)
SELECT documentdb_core.bson_from_json('
{
  "_id": {"$oid": "6587f191e810c19729de8604"},
  "role": "userAdmin",
  "is_builtin": true,
  "description": "Provides user and role administration privileges",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": [
        "createUser", "dropUser", "updateUser",
        "createRole", "dropRole", "updateRole",
        "grantRole", "revokeRole",
        "viewUser", "viewRole"
      ]
    }
  ],
  "roles": []
}')
WHERE NOT EXISTS (
    SELECT 1 FROM documentdb_api_catalog.roles 
    WHERE document->>'role' = 'userAdmin'
);

-- Built-in Role: root
-- Superuser role with all privileges (inherits from readWrite, dbAdmin, and userAdmin)
INSERT INTO documentdb_api_catalog.roles (document)
SELECT documentdb_core.bson_from_json('
{
  "_id": {"$oid": "6587f191e810c19729de8605"},
  "role": "root",
  "is_builtin": true,
  "description": "Superuser role with all privileges",
  "privileges": [
    {
      "resource": {"db": "", "collection": ""},
      "actions": [
        "find", "insert", "update", "remove",
        "createCollection", "dropCollection",
        "createIndex", "dropIndex",
        "collMod", "collStats", "dbStats",
        "listCollections", "listIndexes", "listDatabases",
        "createUser", "dropUser", "updateUser",
        "createRole", "dropRole", "updateRole",
        "grantRole", "revokeRole",
        "viewUser", "viewRole",
        "changeStream", "bypassDocumentValidation",
        "compact", "validate"
      ]
    }
  ],
  "roles": ["readWrite", "dbAdmin", "userAdmin"]
}')
WHERE NOT EXISTS (
    SELECT 1 FROM documentdb_api_catalog.roles 
    WHERE document->>'role' = 'root'
);

-- Verify all built-in roles were inserted
DO $$
DECLARE
    role_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO role_count
    FROM documentdb_api_catalog.roles
    WHERE document->>'is_builtin' = 'true';
    
    IF role_count < 5 THEN
        RAISE WARNING 'Expected 5 built-in roles, but found %. Check for errors.', role_count;
    END IF;
END $$;
