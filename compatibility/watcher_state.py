# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Bounded metadata access and non-force Git persistence for watcher state."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from compatibility.contracts import validate_schema

STATE_BRANCH = "compatibility-watcher-state"
MAX_STATE_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
BOT = {
    "name": "github-actions[bot]",
    "email": "41898282+github-actions[bot]@users.noreply.github.com",
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def json_digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


class RequestError(RuntimeError):
    def __init__(self, message: str, status: int | None = None, retryable: bool = False):
        super().__init__(message)
        self.status = status
        self.retryable = retryable


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str
    ) -> None:
        return None


def request_json(
    url: str, *, token: str | None = None, method: str = "GET", payload: Any = None
) -> Any:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc not in {"api.github.com", "pypi.org"}
        or (token is not None and parsed.netloc != "api.github.com")
        or (parsed.netloc == "pypi.org" and not parsed.path.startswith("/pypi/pymongo/"))
    ):
        raise ValueError("Metadata request is outside the reviewed public sources")
    headers = {"Accept": "application/json", "User-Agent": "documentdb-compatibility"}
    if parsed.netloc == "api.github.com":
        headers["Accept"] = "application/vnd.github+json"
        headers["X-GitHub-Api-Version"] = "2026-03-10"
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url,
        data=canonical_bytes(payload) if payload is not None else None,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            contents = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        retryable = error.code == 429 or (
            error.code == 403
            and (
                error.headers.get("Retry-After") is not None
                or error.headers.get("X-RateLimit-Remaining") == "0"
            )
        )
        raise RequestError(
            f"Metadata API returned HTTP {error.code}", error.code, retryable
        ) from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise RequestError(
            "Metadata API connection failed; request outcome may be unknown"
        ) from error
    if len(contents) > MAX_RESPONSE_BYTES:
        raise RequestError("Metadata API response exceeded its size limit")
    try:
        return json.loads(contents) if contents else None
    except (ValueError, UnicodeError) as error:
        raise RequestError("Metadata API returned invalid JSON") from error


class GitHub:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not token:
            raise ValueError("A repository-scoped GitHub token and repository are required")
        self.repository = repository
        self.token = token

    def request(self, method: str, path: str, payload: Any = None) -> Any:
        if not path.startswith("/repos/"):
            raise ValueError("Unsupported GitHub API path")
        return request_json(
            "https://api.github.com" + path, token=self.token, method=method, payload=payload
        )

    def local(self, method: str, path: str, payload: Any = None) -> Any:
        return self.request(method, f"/repos/{self.repository}{path}", payload)


class GitLedger:
    def __init__(self, api: GitHub):
        self.api = api
        self.head: str | None = None
        self.state: dict[str, Any] = {"schema_version": 1, "entries": {}, "last_scan": None}

    def load(self) -> None:
        try:
            reference = self.api.local("GET", f"/git/ref/heads/{STATE_BRANCH}")
        except RequestError as error:
            if error.status != 404:
                raise
            return
        self.head = reference["object"]["sha"]
        if not isinstance(self.head, str) or not re.fullmatch(r"[a-f0-9]{40}", self.head):
            raise ValueError("Invalid watcher state revision")
        commit = self.api.local("GET", f"/git/commits/{self.head}")
        tree = self.api.local("GET", f"/git/trees/{commit['tree']['sha']}")
        files = tree["tree"]
        if (
            tree.get("truncated") is not False
            or len(files) != 1
            or files[0]["path"] != "ledger.json"
            or files[0]["type"] != "blob"
            or files[0]["mode"] != "100644"
            or files[0]["size"] > MAX_STATE_BYTES
        ):
            raise ValueError("Watcher state must contain only a bounded, regular ledger.json")
        blob = self.api.local("GET", f"/git/blobs/{files[0]['sha']}")
        if blob["encoding"] != "base64":
            raise ValueError("Unsupported watcher state encoding")
        contents = base64.b64decode(blob["content"].replace("\n", ""), validate=True)
        if len(contents) > MAX_STATE_BYTES:
            raise ValueError("Watcher state exceeded its size limit")
        self.state = json.loads(contents)
        validate_schema(self.state, "watcher")

    def save(self) -> None:
        """Advance only from the loaded parent; conflicts stop before any new dispatch."""
        validate_schema(self.state, "watcher")
        contents = canonical_bytes(self.state)
        if len(contents) > MAX_STATE_BYTES:
            raise ValueError(
                "Watcher ledger is full; review retention without deleting its audit trail"
            )
        tree = self.api.local(
            "POST",
            "/git/trees",
            {
                "tree": [
                    {
                        "path": "ledger.json",
                        "mode": "100644",
                        "type": "blob",
                        "content": contents.decode(),
                    }
                ]
            },
        )
        commit = self.api.local(
            "POST",
            "/git/commits",
            {
                "message": "Record compatibility watcher state\n\n"
                f"Signed-off-by: {BOT['name']} <{BOT['email']}>",
                "tree": tree["sha"],
                "parents": [self.head] if self.head is not None else [],
                "author": BOT,
            },
        )
        if self.head is None:
            self.api.local(
                "POST",
                "/git/refs",
                {"ref": f"refs/heads/{STATE_BRANCH}", "sha": commit["sha"]},
            )
        else:
            self.api.local(
                "PATCH",
                f"/git/refs/heads/{STATE_BRANCH}",
                {"sha": commit["sha"], "force": False},
            )
        self.head = commit["sha"]
