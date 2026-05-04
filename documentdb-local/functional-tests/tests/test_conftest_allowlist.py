"""
Tests for conftest_allowlist.py plugin.

Uses subprocess to run pytest with the plugin against small fixture test
suites without needing the full upstream functional-tests image.
"""
import os
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

PLUGIN_PATH = str(Path(__file__).parent.parent / "tools" / "conftest_allowlist.py")


@pytest.fixture
def test_dir(tmp_path):
    """Create a temporary test directory with the plugin available."""
    plugin_dir = tmp_path / "plugins"
    plugin_dir.mkdir()
    # Copy plugin
    import shutil
    shutil.copy(PLUGIN_PATH, plugin_dir / "conftest_allowlist.py")
    return tmp_path


def write_allowlist(path, test_ids, schema_version=1, raw=None):
    """Write an allowlist.yml file."""
    if raw is not None:
        path.write_text(raw)
    else:
        data = {"schema_version": schema_version, "tests": test_ids}
        path.write_text(yaml.dump(data, default_flow_style=False))
    return str(path)


def run_pytest(test_dir, test_code, allowlist_args=None, extra_args=None, ini_content=None):
    """Run pytest in a subprocess with the plugin loaded."""
    test_file = test_dir / "test_sample.py"
    test_file.write_text(test_code)

    if ini_content:
        (test_dir / "pytest.ini").write_text(ini_content)

    plugin_dir = test_dir / "plugins"
    env = os.environ.copy()
    env["PYTHONPATH"] = str(plugin_dir) + os.pathsep + env.get("PYTHONPATH", "")

    cmd = [sys.executable, "-m", "pytest", str(test_file),
           "-p", "no:cacheprovider", "-p", "conftest_allowlist"]
    if allowlist_args:
        cmd.extend(allowlist_args)
    if extra_args:
        cmd.extend(extra_args)

    result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(test_dir), env=env)
    return result


class TestAllowlistSelection:
    def test_selects_only_allowlisted(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_included"])
        r = run_pytest(test_dir,
                       "def test_included():\n    pass\ndef test_excluded():\n    pass\n",
                       [f"--allowlist={al}"], ["-v"])
        assert r.returncode == 0
        assert "test_included PASSED" in r.stdout
        assert "1 deselected" in r.stdout

    def test_all_allowlisted_pass(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_a", "test_sample.py::test_b"])
        r = run_pytest(test_dir,
                       "def test_a():\n    pass\ndef test_b():\n    pass\n",
                       [f"--allowlist={al}"], ["-v"])
        assert r.returncode == 0
        assert "2 passed" in r.stdout


class TestMissingIDs:
    def test_missing_id_fails(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_real",
                              "test_sample.py::test_does_not_exist"])
        r = run_pytest(test_dir,
                       "def test_real():\n    pass\n",
                       [f"--allowlist={al}"])
        assert r.returncode != 0
        assert "UNKNOWN_TEST_ID" in r.stderr


class TestDuplicateIDs:
    def test_duplicate_fails(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_a", "test_sample.py::test_a"])
        r = run_pytest(test_dir,
                       "def test_a():\n    pass\n",
                       [f"--allowlist={al}"])
        assert r.returncode != 0
        assert "DUPLICATE_TEST_ID" in r.stderr


class TestNoParallel:
    def test_no_parallel_rejected(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_seq"])
        code = ("import pytest\n\n"
                "@pytest.mark.no_parallel\n"
                "def test_seq():\n    pass\n")
        ini = ("[pytest]\nmarkers =\n"
               "    no_parallel: Tests that must run sequentially\n")
        r = run_pytest(test_dir, code, [f"--allowlist={al}"], ini_content=ini)
        assert r.returncode != 0
        assert "ALLOWLISTED_NO_PARALLEL" in r.stderr


class TestEngineXfail:
    def test_engine_xfail_rejected(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_unsupported"])
        code = ("import pytest\n\n"
                '@pytest.mark.engine_xfail(engine="documentdb", reason="not supported")\n'
                "def test_unsupported():\n    pass\n")
        ini = ("[pytest]\nmarkers =\n"
               "    engine_xfail(engine, reason, raises): expected failure for a specific engine\n")
        r = run_pytest(test_dir, code,
                       [f"--allowlist={al}", "--allowlist-engine-name=documentdb"],
                       ini_content=ini)
        assert r.returncode != 0
        assert "ALLOWLISTED_ENGINE_XFAIL" in r.stderr

    def test_different_engine_not_rejected(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml",
                             ["test_sample.py::test_mongo_issue"])
        code = ("import pytest\n\n"
                '@pytest.mark.engine_xfail(engine="mongodb", reason="mongo only")\n'
                "def test_mongo_issue():\n    pass\n")
        ini = ("[pytest]\nmarkers =\n"
               "    engine_xfail(engine, reason, raises): expected failure for a specific engine\n")
        r = run_pytest(test_dir, code,
                       [f"--allowlist={al}", "--allowlist-engine-name=documentdb"],
                       ini_content=ini)
        assert r.returncode == 0
        assert "1 passed" in r.stdout


class TestInvalidSchema:
    def test_bad_schema_version(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml", [], schema_version=99)
        r = run_pytest(test_dir, "def test_a():\n    pass\n", [f"--allowlist={al}"])
        assert r.returncode != 0
        assert "INVALID_SCHEMA" in r.stderr

    def test_not_a_mapping(self, test_dir):
        al = write_allowlist(test_dir / "allowlist.yml", [], raw="- just a list\n")
        r = run_pytest(test_dir, "def test_a():\n    pass\n", [f"--allowlist={al}"])
        assert r.returncode != 0
        assert "INVALID_SCHEMA" in r.stderr


class TestNoAllowlist:
    def test_loaded_plugin_requires_allowlist(self, test_dir):
        r = run_pytest(test_dir,
                        "def test_a():\n    pass\ndef test_b():\n    pass\n")
        assert r.returncode != 0
        assert "MISSING_ALLOWLIST" in r.stderr
