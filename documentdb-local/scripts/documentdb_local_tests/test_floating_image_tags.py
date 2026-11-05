# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # documentdb_local_tests.yml installs PyYAML
    yaml = None

OSS_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = OSS_ROOT / "packaging" / "floating-image-tags.sh"
POLICY = OSS_ROOT / "packaging" / "stable-series"
WORKFLOW = OSS_ROOT / ".github" / "workflows" / "build_gateway.yml"
CHANGELOG = OSS_ROOT / "CHANGELOG.md"
REPO = "https://example.invalid/documentdb"


def release_ref(version):
    series, patch = version.rsplit(".", 1)
    return f"refs/tags/v{series}-{patch}"


def git_env():
    # The caller's GIT_DIR or signing config must not reach the fixture repository.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return env


class FloatingImageTagsTests(unittest.TestCase):
    """packaging/floating-image-tags.sh against a real repository; REPO in args stands for it."""

    def run_script(self, *args, tags=(), reachable=True, fail_lookups=0):
        env = dict(git_env(), FLOATING_TAGS_RETRY_DELAY="0")
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as bin_dir:
            if fail_lookups:
                # A git that fails its first N ls-remote calls, like a network blip.
                fake = Path(bin_dir, "git")
                fake.write_text(f'#!/bin/sh\nif [ "$1" = ls-remote ]; then\n'
                                f'  n=$(cat "$0.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$0.n"\n'
                                f'  [ "$n" -lt {fail_lookups} ] && exit 128\nfi\n'
                                f'exec {shutil.which("git")} "$@"\n', encoding="utf-8")
                fake.chmod(0o755)
                env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            git = ["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t"]
            subprocess.run(git + ["init", "-q"], check=True, env=env)
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "x"], check=True, env=env)
            for i, tag in enumerate(tags):
                # Release tags may be annotated or lightweight.
                kind = ["-a", "-m", tag] if i % 2 else []
                subprocess.run(git + ["tag", *kind, tag], check=True, env=env)
            url = root if reachable else str(Path(root) / "missing")
            return subprocess.run(["bash", str(SCRIPT), *(url if a == REPO else a for a in args)],
                                  capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                  timeout=30, env=env)

    def tags_for(self, version, tags, stable="1.0"):
        r = self.run_script("--repo", REPO, "--ref", release_ref(version), "--stable-series", stable, version,
                            tags=tags)
        self.assertEqual(r.returncode, 0, r.stderr)
        # Exact output: the workflow takes the first word as MANIFEST_TAG, so a leading space would blank it.
        return r.stdout.removesuffix("\n")

    def test_moves_only_tags_this_release_is_newest_for(self):
        cases = [
            # (version, existing release tags, expected floating tags)
            ("1.0.0", ["v0.117-0", "v1.0-0", "v1.0-RC2"], "latest 1.0 stable"),
            ("1.0.1", ["v1.0-0", "v1.0-1"], "latest 1.0 stable"),
            ("1.0.1", ["v1.0-1", "v1.0-2"], ""),
            ("1.0.3", ["v1.0-2", "v1.1-0"], "1.0 stable"),
            ("1.1.0", ["v1.0-2", "v1.1-0", "v1.2-RC1"], "latest 1.1"),
            ("1.0.9", ["v1.0-9", "v1.0-10"], ""),
            ("1.1.0", ["v1.10-0", "v1.1-0"], "1.1"),
            ("1.0.0", [], "latest 1.0 stable"),
        ]
        for version, tags, expected in cases:
            with self.subTest(version=version, tags=tags):
                self.assertEqual(self.tags_for(version, tags), expected)

    def test_every_changelog_version_is_accepted(self):
        # The workflow passes the dotted form of each release heading (v1.3-0 -> 1.3.0).
        headings = re.findall(r"^### documentdb v(\d+\.\d+)-(\d+)\b", CHANGELOG.read_text(encoding="utf-8"), re.M)
        self.assertTrue(headings, "no release headings found in CHANGELOG.md")
        for series, patch in headings:
            with self.subTest(version=f"{series}.{patch}"):
                self.assertEqual(self.tags_for(f"{series}.{patch}", [], stable=series),
                                 f"latest {series} stable")

    def test_release_timeline_through_upcoming_versions(self):
        # Releases in the order they could ship, including patches to older
        # series after newer ones; stable is promoted from 1.0 to 1.2 midway.
        steps = [
            ("1.0.0", "1.0", "latest 1.0 stable"),
            ("1.0.1", "1.0", "latest 1.0 stable"),
            ("1.1.0", "1.0", "latest 1.1"),
            ("1.0.2", "1.0", "1.0 stable"),
            ("1.2.0", "1.0", "latest 1.2"),
            ("1.1.1", "1.0", "1.1"),
            ("1.2.1", "1.2", "latest 1.2 stable"),
            ("1.0.3", "1.2", "1.0"),
            ("1.3.0", "1.2", "latest 1.3"),
            ("1.2.2", "1.2", "1.2 stable"),
            ("1.2.1", "1.2", ""),
        ]
        released, floating = [], {}
        for version, stable, expected in steps:
            series, patch = version.rsplit(".", 1)
            if f"v{series}-{patch}" not in released:
                released.append(f"v{series}-{patch}")
            with self.subTest(version=version, stable=stable):
                moved = self.tags_for(version, released, stable=stable)
                self.assertEqual(moved, expected)
            for tag in moved.split():
                floating[tag] = version
        self.assertEqual(floating, {"latest": "1.3.0", "stable": "1.2.2", "1.0": "1.0.3",
                                    "1.1": "1.1.1", "1.2": "1.2.2", "1.3": "1.3.0"})

    def test_blank_stable_series_never_moves_stable(self):
        self.assertEqual(self.tags_for("1.0.0", ["v1.0-0"], stable=""), "latest 1.0")

    def test_shipped_stable_series_is_accepted(self):
        # Raw bytes, as `git show` hands them to the workflow, so a stray CR fails here too.
        stable = POLICY.read_bytes().decode("utf-8").rstrip("\n")
        self.assertIn(self.tags_for("1.0.0", ["v1.0-0"], stable=stable), ("latest 1.0 stable", "latest 1.0"))

    def test_failed_tag_lookup_fails(self):
        r = self.run_script("--repo", REPO, "--ref", release_ref("1.0.1"), "1.0.1", tags=["v1.0-0"],
                            reachable=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_transient_lookup_failure_is_retried(self):
        args = ("--repo", REPO, "--ref", release_ref("1.0.1"), "1.0.1")
        r = self.run_script(*args, tags=["v1.0-0"], fail_lookups=2)
        self.assertEqual((r.returncode, r.stdout), (0, "latest 1.0\n"), r.stderr)
        r = self.run_script(*args, tags=["v1.0-0"], fail_lookups=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_release_candidate_moves_nothing(self):
        for version in ("1.1~rc1", "1.1-rc1", "1.1.0-RC1"):
            with self.subTest(version=version):
                r = self.run_script("--repo", REPO, version, reachable=False)
                self.assertEqual((r.returncode, r.stdout), (0, ""), r.stderr)

    def test_only_the_releases_own_tag_moves_anything(self):
        # A dispatch on any other ref, tag or not, takes its version from an input or the control file.
        for ref in ("refs/heads/main", "refs/tags/snapshot", "refs/tags/V1.0-1", "refs/tags/1.0.1",
                    "refs/tags/v1.0-0", "refs/tags/v1.0-1-fix", ""):
            with self.subTest(ref=ref):
                r = self.run_script("--repo", REPO, "--ref", ref, "--stable-series", "1.0", "1.0.1",
                                    tags=["v1.0-0"], reachable=False)
                self.assertEqual((r.returncode, r.stdout), (0, "\n"), r.stderr)

    def test_rejects_bad_input(self):
        for args in (["--repo", REPO, "1.0"], ["--repo", REPO, "v1.0-0"], ["1.0.0"],
                     ["--repo", REPO, "--stable-series", "1.0.0", "1.0.0"], ["--repo"],
                     ["--repo", REPO, "1.0.0", "1.0.1"], ["--repo", REPO, "1.0.0"],
                     ["--ref", "refs/tags/v1.0-0", "1.0.0"]):
            with self.subTest(args=args):
                r = self.run_script(*args, tags=["v1.0-0"])
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(r.stdout, "")


def floating_tags_step(name):
    steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["create-manifest-latest"]["steps"]
    return next(s["run"] for s in steps if s.get("name") == name)


@unittest.skipIf(yaml is None, "needs PyYAML")
class FloatingTagsStepTests(unittest.TestCase):
    """build_gateway.yml's floating-tag steps, run with bash."""

    def run_step(self, version):
        # The picker, from a release checkout against a real origin.
        script = floating_tags_step("Pick floating tags")
        env = git_env()
        with tempfile.TemporaryDirectory() as root:
            origin, checkout, github_env = (Path(root, n) for n in ("origin", "checkout", "github_env"))
            script = script.replace("${{ github.server_url }}/${{ github.repository }}", str(origin))
            self.assertNotIn("${{", script)

            def git(*args):
                subprocess.run(["git", "-C", str(origin), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                               check=True, capture_output=True, env=env)

            def commit_policy(policy):
                (origin / "packaging").mkdir(parents=True, exist_ok=True)
                (origin / "packaging" / "stable-series").write_bytes(policy)
                git("add", "-A")
                git("commit", "-q", "-m", policy.decode())

            # main promoted stable to 1.2 after release/1.0 branched off with 1.0.
            subprocess.run(["git", "init", "-q", "-b", "main", str(origin)], check=True, env=env)
            commit_policy(b"1.0\n")
            git("tag", "v1.0-3")
            git("branch", "release/1.0")
            commit_policy(b"1.2\n")
            git("tag", "v1.2-0")
            git("checkout", "-q", "release/1.0")
            git("commit", "-q", "--allow-empty", "-m", "1.0.4")
            git("tag", "v1.0-4")
            git("checkout", "-q", "main")
            # Shallow and detached at the release tag, as actions/checkout leaves it.
            subprocess.run(["git", "clone", "-q", "--depth=1", "--branch", "v1.0-4", f"file://{origin}",
                            str(checkout)], check=True, capture_output=True, env=env)
            shutil.copy(SCRIPT, checkout / "packaging")
            r = subprocess.run(["bash", "-c", f"set -euo pipefail\n{script}"], cwd=checkout,
                               capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60,
                               env=dict(env, VERSION=version, GITHUB_REF=release_ref(version),
                                        GITHUB_ENV=str(github_env)))
            return r, github_env.read_text(encoding="utf-8") if github_env.exists() else ""

    def test_stable_follows_the_default_branch_not_the_release_checkout(self):
        r, written = self.run_step("1.0.4")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(written, "MANIFEST_TAG=1.0\nFLOATING_TAGS=1.0\n")
        self.assertNotIn("::warning::", r.stdout)

    def test_a_release_that_moves_nothing_warns(self):
        r, written = self.run_step("1.0.3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(written, "MANIFEST_TAG=\nFLOATING_TAGS=\n")
        self.assertIn("::warning::1.0.3 moves no floating tag", r.stdout)

    def test_each_floating_tag_is_pushed_from_the_pg17_images(self):
        script = (floating_tags_step("Create and Push Manifest")
                  .replace("${{ env.FLOATING_TAGS }}", "latest 1.0 stable")
                  .replace("${{ github.repository }}", "documentdb/documentdb")
                  .replace("${{ env.IMAGE_NAME }}", "documentdb-local")
                  .replace("${{ env.IMAGE_TAG }}", "42"))
        self.assertNotIn("${{", script)
        with tempfile.TemporaryDirectory() as root:
            log, docker = Path(root, "docker.log"), Path(root, "docker")
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n', encoding="utf-8")
            docker.chmod(0o755)
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, timeout=30,
                               env=dict(os.environ, PATH=f"{root}{os.pathsep}{os.environ['PATH']}",
                                        DOCKER_LOG=str(log)))
            self.assertEqual(r.returncode, 0, r.stderr)
            calls = log.read_text(encoding="utf-8").splitlines()
        image = "ghcr.io/documentdb/documentdb/documentdb-local"
        sources = f"--amend {image}:42-pg17-amd64 --amend {image}:42-pg17-arm64"
        expected = []
        for tag in ("latest", "1.0", "stable"):
            expected += [f"manifest create {image}:{tag} {sources}", f"manifest push {image}:{tag}"]
        self.assertEqual(calls, expected)


if __name__ == "__main__":
    unittest.main()
