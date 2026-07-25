"""Smoke tests that run inside the dev container against the DocumentDB
sidecar. `pytest` from the integrated terminal is all it takes -- the
DOCUMENTDB_URI environment variable is provided by the compose file, and the
sidecar is already healthy by the time the dev container starts."""

import os

import pymongo
import pytest


@pytest.fixture(scope="module")
def client():
    uri = os.environ.get(
        "DOCUMENTDB_URI",
        # Fallback for running the same tests on the host against
        # ../compose-quickstart (where the port is published to localhost).
        "mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true",
    )
    client = pymongo.MongoClient(uri, serverSelectionTimeoutMS=20000)
    yield client
    client.close()


def test_ping(client):
    assert client.admin.command("ping")["ok"] == 1


def test_crud_roundtrip(client):
    collection = client.devcontainer_example.smoke
    collection.delete_many({})
    collection.insert_many([{"n": i} for i in range(5)])
    assert collection.count_documents({}) == 5
    assert collection.count_documents({"n": {"$gte": 3}}) == 2
    collection.delete_many({})
