"""Minimal DocumentDB client app for the compose-app example.

Inserts a document and reads it back, then exits 0. Because the compose file
gates this container on DocumentDB's healthcheck, no connection-retry loop is
needed: by the time this runs, the database is accepting connections and any
first-boot initialization has finished.
"""

import os
import sys

import pymongo


def main() -> int:
    uri = os.environ["DOCUMENTDB_URI"]
    client = pymongo.MongoClient(uri, serverSelectionTimeoutMS=20000)

    collection = client.compose_example.greetings
    inserted = collection.insert_one({"message": "hello from docker compose"})
    document = collection.find_one({"_id": inserted.inserted_id})
    if document is None:
        print("ERROR: could not read back the inserted document", file=sys.stderr)
        return 1

    print(f"Round-trip succeeded: {document['message']!r}")
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
