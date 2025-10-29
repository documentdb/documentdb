"""Smoke tests for the DocumentDB gateway packaging image."""

from __future__ import annotations

import sys
from typing import Iterator

import pytest  # type: ignore
from pymongo import ASCENDING  # type: ignore
from pymongo import MongoClient  # type: ignore
from pymongo.errors import DuplicateKeyError  # type: ignore


DOCUMENTDB_URI = (
    "mongodb://cloudsa:123456@localhost:10260/"
    "?tls=true&tlsAllowInvalidCertificates=true"
)
DB_NAME = "quickStartDatabase"
COLLECTION_NAME = "quickStartCollection"


@pytest.fixture(scope="module")
def client() -> Iterator[MongoClient]:
    """Provide a MongoClient instance and ensure it closes after tests."""

    mongo_client = MongoClient(DOCUMENTDB_URI)
    try:
        yield mongo_client
    finally:
        mongo_client.close()


@pytest.fixture()
def collection(client: MongoClient):
    """Yield a clean collection for each test run."""

    database = client[DB_NAME]
    database.drop_collection(COLLECTION_NAME)
    coll = database[COLLECTION_NAME]
    try:
        yield coll
    finally:
        database.drop_collection(COLLECTION_NAME)


def test_insert_and_find(collection):
    collection.insert_one(
        {
            "name": "John Doe",
            "email": "john@email.com",
            "address": "123 Main St, Anytown, USA",
            "phone": "555-1234",
        }
    )

    doc = collection.find_one({"name": "John Doe"})
    assert doc is not None
    assert doc["email"] == "john@email.com"
    assert collection.count_documents({}) == 1


def test_insert_many_and_query(collection):
    documents = [
        {
            "name": "Jane Smith",
            "email": "jane@email.com",
            "address": "456 Elm St, Othertown, USA",
            "phone": "555-5678",
            "age": 32,
        },
        {
            "name": "Alice Johnson",
            "email": "alice@email.com",
            "address": "789 Oak St, Sometown, USA",
            "phone": "555-8765",
            "age": 27,
        },
        {
            "name": "Bob Brown",
            "email": "bob@email.com",
            "address": "101 Pine St, Elsewhere, USA",
            "phone": "555-4321",
            "age": 40,
        },
    ]

    collection.insert_many(documents)

    younger_than_35 = list(collection.find({"age": {"$lt": 35}}, {"name": 1, "_id": 0}))
    names = sorted(doc["name"] for doc in younger_than_35)
    assert names == ["Alice Johnson", "Jane Smith"]


def test_update_document(collection):
    collection.insert_one({"name": "Update Me", "email": "initial@example.com"})

    update_result = collection.update_one(
        {"name": "Update Me"},
        {"$set": {"email": "updated@example.com"}},
    )

    assert update_result.matched_count == 1
    assert update_result.modified_count == 1
    updated_doc = collection.find_one({"name": "Update Me"})
    assert updated_doc["email"] == "updated@example.com"


def test_delete_document(collection):
    collection.insert_many(
        [
            {"name": "Delete Me"},
            {"name": "Keep Me"},
        ]
    )

    delete_result = collection.delete_one({"name": "Delete Me"})
    assert delete_result.deleted_count == 1
    assert collection.count_documents({}) == 1
    assert collection.find_one({"name": "Delete Me"}) is None


def test_aggregation_pipeline(collection):
    collection.insert_many(
        [
            {"category": "books", "price": 10},
            {"category": "books", "price": 15},
            {"category": "games", "price": 20},
        ]
    )

    pipeline = [
        {"$group": {"_id": "$category", "avgPrice": {"$avg": "$price"}}},
        {"$sort": {"_id": 1}},
    ]

    results = list(collection.aggregate(pipeline))
    assert results == [
        {"_id": "books", "avgPrice": pytest.approx(12.5)},
        {"_id": "games", "avgPrice": pytest.approx(20)},
    ]


def test_index_creation(collection):
    index_name = collection.create_index("email", unique=True)
    indexes = collection.index_information()

    assert index_name in indexes
    assert indexes[index_name]["unique"] is True


def test_duplicate_key_error(collection):
    collection.create_index("email", unique=True)
    collection.insert_one({"email": "duplicate@example.com"})

    with pytest.raises(DuplicateKeyError):
        collection.insert_one({"email": "duplicate@example.com"})


def test_upsert_operation(collection):
    upsert_result = collection.update_one(
        {"name": "Upsert Me"},
        {"$set": {"name": "Upsert Me", "count": 1}},
        upsert=True,
    )

    assert upsert_result.upserted_id is not None
    doc = collection.find_one({"name": "Upsert Me"})
    assert doc["count"] == 1

    update_result = collection.update_one(
        {"name": "Upsert Me"},
        {"$set": {"count": 2}},
        upsert=True,
    )

    assert update_result.upserted_id is None
    doc = collection.find_one({"name": "Upsert Me"})
    assert doc["count"] == 2


def test_nested_document_queries(collection):
    collection.insert_many(
        [
            {"name": "Nested One", "profile": {"status": "active", "score": 10}},
            {"name": "Nested Two", "profile": {"status": "inactive", "score": 5}},
        ]
    )

    active_docs = list(collection.find({"profile.status": "active"}))
    assert len(active_docs) == 1
    assert active_docs[0]["name"] == "Nested One"


def test_text_search_like_query(collection):
    collection.insert_many(
        [
            {"name": "Case Test", "note": "This is Mixed CASE"},
            {"name": "Another", "note": "lower case"},
        ]
    )

    results = list(
        collection.find(
            {"note": {"$regex": "case", "$options": "i"}},
            {"name": 1, "_id": 0},
        )
    )

    names = sorted(doc["name"] for doc in results)
    assert names == ["Another", "Case Test"]


def test_sort_and_projection(collection):
    collection.insert_many(
        [
            {"name": "Alpha", "score": 10},
            {"name": "Bravo", "score": 30},
            {"name": "Charlie", "score": 20},
        ]
    )

    cursor = collection.find({}, {"_id": 0, "name": 1}).sort("score", ASCENDING)
    ordered_names = [doc["name"] for doc in cursor]
    assert ordered_names == ["Alpha", "Charlie", "Bravo"]


if __name__ == "__main__":
    print("Running DocumentDB gateway smoke tests...")
    sys.exit(pytest.main(["-vv", __file__]))
