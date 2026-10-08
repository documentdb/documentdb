# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""An explicitly labeled failing driver assertion, never a real compatibility verdict."""

import os

import pytest

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        os.environ.get("COMPATIBILITY_ACTIVE") != "1"
        or os.environ.get("COMPATIBILITY_DEMONSTRATION") != "1",
        reason="Only an explicitly requested isolated failure demonstration enables this case",
    ),
]


def test_failure_demonstration(collection):
    """An intentionally incorrect count must produce a failed result and nonzero exit."""
    collection.insert_one({"_id": 1})
    assert (
        collection.count_documents({}) == 0
    ), "Intentional failure demonstration; not a compatibility regression"
