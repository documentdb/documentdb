# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Synchronous driver API coverage, not a full engine feature specification."""

import os
from datetime import datetime, timezone

import pytest
from bson import Decimal128, Int64, ObjectId
from pymongo import ASCENDING, DESCENDING, IndexModel, ReturnDocument
from pymongo.errors import DuplicateKeyError

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        os.environ.get("COMPATIBILITY_ACTIVE") != "1",
        reason="Run this version-pinned profile through compatibility.runner",
    ),
]


def test_authenticated_ping(collection):
    """The selected client authenticates and receives an administrative reply."""
    assert collection.database.client.admin.command("ping")["ok"] == 1


def test_insert_one(collection):
    """InsertOneResult and a subsequent read identify the inserted document."""
    document = {"value": 3}
    result = collection.insert_one(document)
    assert result.acknowledged
    assert isinstance(result.inserted_id, ObjectId)
    assert collection.find_one({"_id": result.inserted_id}) == document


def test_insert_many(collection):
    """InsertManyResult contains every identifier and all documents are readable."""
    documents = [{"_id": 1, "value": 3}, {"_id": 2, "value": 7}]
    result = collection.insert_many(documents)
    assert result.acknowledged
    assert result.inserted_ids == [1, 2]
    assert list(collection.find().sort("_id", ASCENDING)) == documents


def test_find_one(collection):
    """A point lookup returns the exact document, or None for a missing key."""
    document = {"_id": 1, "value": 3}
    collection.insert_one(document)
    assert collection.find_one({"_id": 1}) == document
    assert collection.find_one({"_id": 2}) is None


def test_find_filter_projection_sort_limit(collection):
    """A driver cursor combines filter, projection, sort, and limit correctly."""
    collection.insert_many(
        [{"_id": 1, "price": 3}, {"_id": 2, "price": 7}, {"_id": 3, "price": 11}]
    )
    documents = list(
        collection.find({"price": {"$gte": 5}}, {"_id": 0, "price": 1})
        .sort("price", DESCENDING)
        .limit(1)
    )
    assert documents == [{"price": 11}]


def test_cursor_batches(collection, command_names):
    """Iteration issues getMore and returns every document once across batches."""
    documents = [{"_id": number} for number in range(7)]
    collection.insert_many(documents)
    command_names.names.clear()
    with collection.find().sort("_id", ASCENDING).batch_size(2) as cursor:
        actual = list(cursor)
    assert actual == documents
    assert "find" in command_names.names
    assert "getMore" in command_names.names


def test_count_documents(collection):
    """The driver's count API respects its filter and handles an empty match."""
    collection.insert_many([{"_id": 1, "value": 3}, {"_id": 2, "value": 7}])
    assert collection.count_documents({}) == 2
    assert collection.count_documents({"value": {"$gte": 5}}) == 1
    assert collection.count_documents({"value": 99}) == 0


def test_update_one(collection):
    """UpdateResult counts and readback agree on the applied change."""
    collection.insert_one({"_id": 1, "value": 3})
    result = collection.update_one({"_id": 1}, {"$set": {"value": 7}})
    assert result.acknowledged
    assert (result.matched_count, result.modified_count, result.upserted_id) == (1, 1, None)
    assert collection.find_one({"_id": 1}) == {"_id": 1, "value": 7}


def test_find_one_and_update(collection):
    """ReturnDocument.AFTER returns the changed document rather than the old one."""
    collection.insert_one({"_id": 1, "tags": ["alpha"]})
    document = collection.find_one_and_update(
        {"_id": 1}, {"$push": {"tags": "beta"}}, return_document=ReturnDocument.AFTER
    )
    assert document == {"_id": 1, "tags": ["alpha", "beta"]}
    assert collection.find_one({"_id": 1}) == document


def test_delete_one(collection):
    """DeleteResult and the remaining collection agree on a single deletion."""
    collection.insert_many([{"_id": 1}, {"_id": 2}])
    result = collection.delete_one({"_id": 1})
    assert result.acknowledged
    assert result.deleted_count == 1
    assert list(collection.find()) == [{"_id": 2}]


def test_delete_many(collection):
    """A multi-document deletion returns its count and preserves nonmatching data."""
    collection.insert_many([{"_id": number} for number in range(3)])
    result = collection.delete_many({"_id": {"$lt": 2}})
    assert result.acknowledged
    assert result.deleted_count == 2
    assert list(collection.find()) == [{"_id": 2}]


def test_aggregate(collection):
    """The aggregation cursor yields exact grouped counts in the requested order."""
    collection.insert_many([{"_id": 1, "tags": ["alpha", "beta"]}, {"_id": 2, "tags": ["beta"]}])
    documents = list(
        collection.aggregate(
            [
                {"$unwind": "$tags"},
                {"$group": {"_id": "$tags", "count": {"$sum": 1}}},
                {"$sort": {"_id": 1}},
            ]
        )
    )
    assert documents == [{"_id": "alpha", "count": 1}, {"_id": "beta", "count": 2}]


def test_create_indexes(collection):
    """IndexModel inputs produce the requested scalar and compound index definitions."""
    names = collection.create_indexes(
        [
            IndexModel([("sku", ASCENDING)], name="sku_unique", unique=True),
            IndexModel([("name", ASCENDING), ("price", DESCENDING)], name="name_price"),
        ]
    )
    assert names == ["sku_unique", "name_price"]
    indexes = collection.index_information()
    assert indexes["sku_unique"]["key"] == [("sku", 1)]
    assert indexes["sku_unique"]["unique"] is True
    assert indexes["name_price"]["key"] == [("name", 1), ("price", -1)]


def test_list_indexes(collection):
    """The list_indexes cursor exposes the identifier and a created field index."""
    collection.insert_one({"_id": 1, "value": 3})
    collection.create_index("value", name="value_1")
    indexes = {entry["name"]: entry for entry in collection.list_indexes()}
    assert set(indexes) == {"_id_", "value_1"}
    assert dict(indexes["value_1"]["key"]) == {"value": 1}


def test_drop_index(collection):
    """A dropped field index disappears while the identifier index remains."""
    collection.insert_one({"_id": 1, "value": 3})
    collection.create_index("value", name="value_1")
    collection.drop_index("value_1")
    assert [entry["name"] for entry in collection.list_indexes()] == ["_id_"]


def test_duplicate_key_error(collection):
    """A unique-index violation becomes DuplicateKeyError without inserting data."""
    collection.create_index("sku", unique=True)
    collection.insert_one({"_id": 1, "sku": "one"})
    with pytest.raises(DuplicateKeyError) as raised:
        collection.insert_one({"_id": 2, "sku": "one"})
    assert raised.value.code == 11000
    assert list(collection.find()) == [{"_id": 1, "sku": "one"}]


def test_bson_round_trip(collection):
    """Values and representative BSON types survive insertion and driver decoding."""
    document = {
        "_id": ObjectId(),
        "integer": 7,
        "long": Int64(2**40),
        "double": 2.5,
        "decimal": Decimal128("3.14"),
        "date": datetime(2024, 1, 1, tzinfo=timezone.utc),
        "binary": b"\x00\xff",
        "array": [1, "two", None],
        "boolean": True,
    }
    collection.insert_one(document)
    actual = collection.find_one({"_id": document["_id"]})
    assert actual == document
    assert actual is not None
    for name, value in document.items():
        assert type(actual[name]) is type(value), f"BSON type changed for {name}"
    assert actual["date"].utcoffset() == document["date"].utcoffset()
