# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Disposable namespaces and command-name-only observation for real driver tests."""

import os
import uuid
from collections.abc import Iterator
from datetime import timezone
from typing import Any

import pytest
from bson.codec_options import CodecOptions
from pymongo import MongoClient, monitoring
from pymongo.collection import Collection


class CommandNames(monitoring.CommandListener):
    def __init__(self) -> None:
        self.names: list[str] = []

    def started(self, event: monitoring.CommandStartedEvent) -> None:
        self.names.append(event.command_name)

    def succeeded(self, event: monitoring.CommandSucceededEvent) -> None:
        pass

    def failed(self, event: monitoring.CommandFailedEvent) -> None:
        pass


@pytest.fixture
def command_names() -> CommandNames:
    return CommandNames()


@pytest.fixture
def collection(command_names: CommandNames) -> Iterator[Collection[dict[str, Any]]]:
    client: MongoClient[dict[str, Any]] = MongoClient(
        "db",
        10260,
        username=os.environ["USERNAME"],
        password=os.environ["PASSWORD"],
        authSource="admin",
        directConnection=True,
        tls=True,
        tlsAllowInvalidCertificates=True,
        serverSelectionTimeoutMS=15000,
        connectTimeoutMS=10000,
        socketTimeoutMS=15000,
        event_listeners=[command_names],
        appname="documentdb-pymongo-compatibility",
    )
    database = client.get_database(
        f"compat_{uuid.uuid4().hex}",
        codec_options=CodecOptions(tz_aware=True, tzinfo=timezone.utc),
    )
    try:
        yield database["items"]
    finally:
        try:
            client.drop_database(database.name)
        finally:
            client.close()
