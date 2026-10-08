# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Prepare verified npm archives without executing package code in the controller."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from compatibility.contracts import ROOT, suite_files

REGISTRY = "https://registry.npmjs.org"
MAX_PACKAGE_BYTES = 32 * 1024 * 1024
PACKAGE_NAME = r"(?:@[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9_.-]*"
PACKAGE_PATH = rf"node_modules/{PACKAGE_NAME}(?:/node_modules/{PACKAGE_NAME})*"


def registry_bytes(url: str, limit: int) -> bytes:
    """Keep metadata and package downloads bounded and on the public registry."""
    validate_registry_url(url)
    with urllib.request.urlopen(url, timeout=30) as response:
        if response.geturl() != url:
            raise ValueError("Unexpected npm registry redirect")
        content: bytes = response.read(limit + 1)
    if len(content) > limit:
        raise ValueError("npm registry response exceeded its size limit")
    return content


def validate_registry_url(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "registry.npmjs.org":
        raise ValueError("Package URL is outside the reviewed npm registry")


def verify_integrity(content: bytes, integrity: str) -> str:
    """Check npm's published SHA-512 integrity before recording the archive SHA-256."""
    if not integrity.startswith("sha512-"):
        raise ValueError("npm archive requires SHA-512 integrity")
    expected = base64.b64decode(integrity.removeprefix("sha512-"), validate=True)
    if hashlib.sha512(content).digest() != expected:
        raise ValueError("npm archive does not match its published integrity")
    return hashlib.sha256(content).hexdigest()


def prepare_node_client(
    context: Path,
    spec: dict[str, Any],
    version: str,
    package_cache: Path | None = None,
) -> str:
    """Verify every archive against the reviewed lockfile before an offline installation."""
    integration = Path(spec["test_file"]).parent.name
    for source in suite_files(integration):
        destination = context / source.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    adapter = context / Path(spec["test_file"]).parent
    manifest = json.loads((adapter / "package.json").read_text())
    lock = json.loads((adapter / "package-lock.json").read_text())
    if (
        manifest["dependencies"] != {spec["package"]: version}
        or lock.get("lockfileVersion") != 3
        or not isinstance(lock.get("packages"), dict)
        or not 2 <= len(lock["packages"]) <= 101
        or lock["packages"].get("", {}).get("dependencies") != {spec["package"]: version}
    ):
        raise ValueError("npm lockfile does not match the selected integration")
    packages = context / "npm-packages"
    packages.mkdir()
    if package_cache is not None:
        if package_cache.is_symlink():
            raise ValueError("npm package cache must not be a symbolic link")
        package_cache.mkdir(parents=True, exist_ok=True)
    installed = []
    verified: dict[tuple[str, str], tuple[str, str, str]] = {}
    selected = None
    for path, entry in lock["packages"].items():
        if path == "" or entry.get("optional"):
            continue
        if not re.fullmatch(PACKAGE_PATH, path) or entry.get("link"):
            raise ValueError("npm lockfile contains an unsupported package location")
        name = path.rsplit("node_modules/", 1)[1]
        package_version = entry["version"]
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.-]+)?", package_version):
            raise ValueError("npm lockfile contains an invalid package version")
        identity = (name, package_version)
        if identity not in verified:
            archive_url = entry["resolved"]
            validate_registry_url(archive_url)
            integrity = entry["integrity"]
            cache_name = hashlib.sha256(integrity.encode()).hexdigest() + ".tgz"
            cached = package_cache / cache_name if package_cache is not None else None
            if cached is not None and (cached.exists() or cached.is_symlink()):
                if (
                    cached.is_symlink()
                    or not cached.is_file()
                    or cached.stat().st_size > MAX_PACKAGE_BYTES
                ):
                    raise ValueError("npm package cache entry must be a bounded regular file")
                with cached.open("rb") as file:
                    content = file.read(MAX_PACKAGE_BYTES + 1)
                if len(content) > MAX_PACKAGE_BYTES:
                    raise ValueError("npm package cache entry exceeded its size limit")
            else:
                content = registry_bytes(archive_url, MAX_PACKAGE_BYTES)
            digest = verify_integrity(content, integrity)
            if cached is not None and not cached.exists():
                with tempfile.NamedTemporaryFile(dir=package_cache, delete=False) as temporary:
                    temporary.write(content)
                try:
                    os.replace(temporary.name, cached)
                finally:
                    Path(temporary.name).unlink(missing_ok=True)
            (packages / f"{digest}.tgz").write_bytes(content)
            verified[identity] = (archive_url, integrity, digest)
        archive_url, integrity, digest = verified[identity]
        if entry["resolved"] != archive_url or entry["integrity"] != integrity:
            raise ValueError("Conflicting npm artifacts for the same package version")
        installed.append({"path": path, "name": name, "version": package_version, "sha256": digest})
        if path == f"node_modules/{spec['package']}":
            if package_version != version:
                raise ValueError("Locked driver version does not match the request")
            selected = digest
    if selected is None:
        raise ValueError("npm lockfile is missing the selected driver")
    (context / "package.json").write_text(json.dumps(manifest))
    (context / "package-lock.json").write_text(json.dumps(lock))
    (context / "install-report.json").write_text(json.dumps({"install": installed}))
    return selected
