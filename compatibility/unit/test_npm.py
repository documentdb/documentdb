# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Lockfile provenance and offline npm preparation without executing package code."""

import base64
import hashlib
import json
import shutil
from pathlib import Path

import pytest

from compatibility import npm
from compatibility.contracts import ROOT, read_registry, suite_digest, suite_files

pytestmark = pytest.mark.unit


@pytest.fixture
def npm_fixture(tmp_path, monkeypatch, registry):
    spec = registry["integrations"]["nodejs"]
    version = spec["default_version"]
    source = tmp_path / "source"
    adapter = source / Path(spec["test_file"]).parent
    adapter.mkdir(parents=True)
    content = b"synthetic archive for verification only"
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(content).digest()).decode()
    url = f"{npm.REGISTRY}/{spec['package']}/-/driver-{version}.tgz"
    manifest = {"dependencies": {spec["package"]: version}}
    lock = {
        "lockfileVersion": 3,
        "packages": {
            "": manifest,
            f"node_modules/{spec['package']}": {
                "version": version,
                "resolved": url,
                "integrity": integrity,
            },
        },
    }
    (adapter / "package.json").write_text(json.dumps(manifest))
    (adapter / "package-lock.json").write_text(json.dumps(lock))
    monkeypatch.setattr(npm, "ROOT", source)
    monkeypatch.setattr(npm, "suite_files", lambda integration: list(adapter.glob("*.json")))
    monkeypatch.setattr(npm, "registry_bytes", lambda address, limit: content)
    return spec, version, content, integrity, lock, adapter


def prepare(tmp_path, fixture, cache=None):
    spec, version, _, _, _, _ = fixture
    context = tmp_path / "context"
    context.mkdir()
    return context, npm.prepare_node_client(context, spec, version, cache)


def test_locked_archive_is_verified_and_recorded(tmp_path, npm_fixture):
    context, digest = prepare(tmp_path, npm_fixture)
    spec, version, content, _, _, _ = npm_fixture
    assert digest == hashlib.sha256(content).hexdigest()
    assert json.loads((context / "install-report.json").read_text())["install"] == [
        {
            "path": f"node_modules/{spec['package']}",
            "name": spec["package"],
            "version": version,
            "sha256": digest,
        }
    ]
    assert (context / "npm-packages" / f"{digest}.tgz").read_bytes() == content


def test_verified_cache_can_be_used_without_network(tmp_path, npm_fixture, monkeypatch):
    _, _, content, integrity, _, _ = npm_fixture
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / (hashlib.sha256(integrity.encode()).hexdigest() + ".tgz")).write_bytes(content)

    def unexpected(*args):
        pytest.fail("A complete reviewed cache must not use the network")

    monkeypatch.setattr(npm, "registry_bytes", unexpected)
    _, digest = prepare(tmp_path, npm_fixture, cache)
    assert digest == hashlib.sha256(content).hexdigest()


def test_corrupt_cached_archive_is_rejected(tmp_path, npm_fixture):
    _, _, _, integrity, _, _ = npm_fixture
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / (hashlib.sha256(integrity.encode()).hexdigest() + ".tgz")).write_bytes(b"corrupted")
    with pytest.raises(ValueError, match="integrity"):
        prepare(tmp_path, npm_fixture, cache)


def test_downloaded_archive_is_verified_before_caching(tmp_path, npm_fixture, monkeypatch):
    monkeypatch.setattr(npm, "registry_bytes", lambda *args: b"corrupted")
    cache = tmp_path / "cache"
    with pytest.raises(ValueError, match="integrity"):
        prepare(tmp_path, npm_fixture, cache)
    assert not list(cache.iterdir())


def test_cache_population_is_reusable(tmp_path, npm_fixture):
    _, _, content, integrity, _, _ = npm_fixture
    cache = tmp_path / "cache"
    prepare(tmp_path, npm_fixture, cache)
    assert list(cache.iterdir()) == [
        cache / (hashlib.sha256(integrity.encode()).hexdigest() + ".tgz")
    ]
    assert next(cache.iterdir()).read_bytes() == content


def test_cache_symlinks_are_rejected(tmp_path, npm_fixture):
    _, _, content, integrity, _, _ = npm_fixture
    original = tmp_path / "archive"
    original.write_bytes(content)
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / (hashlib.sha256(integrity.encode()).hexdigest() + ".tgz")).symlink_to(original)
    with pytest.raises(ValueError, match="regular file"):
        prepare(tmp_path, npm_fixture, cache)


@pytest.mark.parametrize(
    "url", ["http://registry.npmjs.org/driver.tgz", "https://example.test/driver.tgz"]
)
def test_lockfile_cannot_fetch_from_an_unreviewed_source(tmp_path, npm_fixture, url):
    spec, _, _, _, lock, adapter = npm_fixture
    lock["packages"][f"node_modules/{spec['package']}"]["resolved"] = url
    (adapter / "package-lock.json").write_text(json.dumps(lock))
    with pytest.raises(ValueError, match="registry"):
        prepare(tmp_path, npm_fixture)


def test_dependency_locations_cannot_escape_node_modules(tmp_path, npm_fixture):
    spec, _, _, _, lock, adapter = npm_fixture
    lock["packages"]["node_modules/../../outside"] = lock["packages"].pop(
        f"node_modules/{spec['package']}"
    )
    (adapter / "package-lock.json").write_text(json.dumps(lock))
    with pytest.raises(ValueError, match="location"):
        prepare(tmp_path, npm_fixture)


def test_unreviewed_driver_version_is_rejected(tmp_path, npm_fixture):
    spec, version, _, _, _, _ = npm_fixture
    context = tmp_path / "context"
    context.mkdir()
    major, minor, patch = version.split(".")
    with pytest.raises(ValueError, match="lockfile"):
        npm.prepare_node_client(context, spec, f"{major}.{minor}.{int(patch) + 1}")


def test_weaker_or_malformed_integrity_is_rejected():
    for integrity in ("sha1-invalid", "sha512-***", "sha512-YWJj"):
        with pytest.raises(ValueError):
            npm.verify_integrity(b"archive", integrity)


def test_reviewed_node_manifest_and_lock_match_the_registry():
    spec = read_registry()["integrations"]["nodejs"]
    adapter = ROOT / Path(spec["test_file"]).parent
    manifest = json.loads((adapter / "package.json").read_text())
    lock = json.loads((adapter / "package-lock.json").read_text())
    assert manifest["dependencies"] == {spec["package"]: spec["default_version"]}
    assert lock["packages"][""]["dependencies"] == manifest["dependencies"]
    assert lock["packages"][f"node_modules/{spec['package']}"]["version"] == spec["default_version"]


def test_node_source_and_lock_are_part_of_provenance(tmp_path):
    spec = read_registry()["integrations"]["nodejs"]
    for source in suite_files("nodejs"):
        destination = tmp_path / source.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    original = suite_digest("nodejs", spec, tmp_path)
    assert original == suite_digest("nodejs", spec)
    lock = tmp_path / Path(spec["test_file"]).parent / "package-lock.json"
    lock.write_text(lock.read_text() + "\n")
    assert suite_digest("nodejs", spec, tmp_path) != original
