# SPDX-License-Identifier: MIT

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


OSS_ROOT = Path(__file__).resolve().parents[2]


def extract_guard(relative_path, start, end):
    text = (OSS_ROOT / relative_path).read_text()
    start_index = text.index(start)
    end_index = text.index(end, start_index)
    return text[start_index:end_index]


RPM_GUARD = extract_guard(
    "packaging/rpm/packaging-entrypoint-rpm.sh",
    "shopt -s nullglob\nrpm_files=",
    "\n# Also handle source RPMs",
)
DEB_GUARD = extract_guard(
    "packaging/deb/packaging-entrypoint.sh",
    "shopt -s nullglob\ndeb_files=",
    "\n# Rename .deb files",
)

RPM_STUB = r"""
rpm() {
    case "$2" in
        --list)
            [[ -z "${RPM_LIST:-}" ]] || printf '%s\n' "$RPM_LIST"
            return "${RPM_LIST_STATUS:-0}"
            ;;
        --provides)
            [[ -z "${RPM_PROVIDES:-}" ]] || printf '%s\n' "$RPM_PROVIDES"
            return "${RPM_PROVIDES_STATUS:-0}"
            ;;
        --requires)
            [[ -z "${RPM_REQUIRES:-}" ]] || printf '%s\n' "$RPM_REQUIRES"
            return "${RPM_REQUIRES_STATUS:-0}"
            ;;
        --conflicts)
            [[ -z "${RPM_CONFLICTS:-}" ]] || printf '%s\n' "$RPM_CONFLICTS"
            return "${RPM_CONFLICTS_STATUS:-0}"
            ;;
        --obsoletes)
            [[ -z "${RPM_OBSOLETES:-}" ]] || printf '%s\n' "$RPM_OBSOLETES"
            return "${RPM_OBSOLETES_STATUS:-0}"
            ;;
    esac
    return 2
}
mv() { return 0; }
"""

DPKG_STUB = r"""
dpkg-deb() {
    if [[ "$1" == "-c" ]]; then
        [[ -z "${DPKG_CONTENTS:-}" ]] || printf '%s\n' "$DPKG_CONTENTS"
        return "${DPKG_CONTENTS_STATUS:-0}"
    fi
    if [[ "$1" != "-f" ]]; then
        return 2
    fi
    shift 2
    if [[ "$1" == "Auto-Built-Package" ]]; then
        [[ -z "${DPKG_AUTO:-}" ]] || printf '%s\n' "$DPKG_AUTO"
        return "${DPKG_AUTO_STATUS:-0}"
    fi
    if [[ "$1" == "Static-Built-Using" ]]; then
        [[ -z "${DPKG_SBU:-}" ]] || printf '%s\n' "$DPKG_SBU"
        return "${DPKG_SBU_STATUS:-0}"
    fi
    if [[ "$1" == "Bundled" ]]; then
        [[ -z "${DPKG_BUNDLED:-}" ]] || printf '%s\n' "$DPKG_BUNDLED"
        return "${DPKG_BUNDLED_STATUS:-0}"
    fi
    [[ -z "${DPKG_CONTROL:-}" ]] || printf '%s\n' "$DPKG_CONTROL"
    return "${DPKG_CONTROL_STATUS:-0}"
}
"""


class GuardTestCase(unittest.TestCase):
    def run_guard(self, kind, overrides=None, create_package=True):
        overrides = overrides or {}
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            env = os.environ.copy()
            env.update(
                {
                    "HOME": temp_dir,
                    "LIBBSON_VER": "1.28.0",
                    "PCRE2_VER": "10.42",
                    "IDML_VER": "2.0u3" if kind == "rpm" else "2.0u3-1",
                    "OS": "test",
                }
            )
            env.update(overrides)

            if kind == "rpm":
                package_dir = temp_path / "rpmbuild" / "RPMS" / "x86_64"
                package_dir.mkdir(parents=True)
                if create_package:
                    (package_dir / "documentdb.rpm").touch()
                env["RPM_ARCH"] = "x86_64"
                script = f"set -e\n{RPM_STUB}\n{RPM_GUARD}"
            else:
                if create_package:
                    (temp_path / overrides.get("DEB_NAME", "documentdb.deb")).touch()
                script = f"set -e\n{DPKG_STUB}\n{DEB_GUARD}"

            return subprocess.run(
                ["bash", "-c", script],
                cwd=temp_dir,
                env=env,
                universal_newlines=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_fails(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)


class RpmGuardTests(GuardTestCase):
    required_provides = (
        "bundled(libbson) = 1.28.0",
        "bundled(pcre2) = 10.42",
        "bundled(intel-decimal-math) = 2.0u3",
    )
    valid_provides = "\n".join(required_provides)

    def test_valid_exact_bundled_provide(self):
        self.assert_passes(
            self.run_guard("rpm", {"RPM_PROVIDES": self.valid_provides})
        )

    def test_rejects_libbson_files_relationships_and_soname(self):
        cases = (
            ("RPM_LIST", "/usr/lib64/libbson-1.0.so.0", "rpm -qp --list"),
            ("RPM_REQUIRES", "libbson >= 1.28", "rpm -qp --requires"),
            ("RPM_CONFLICTS", "libbson < 1.28", "rpm -qp --conflicts"),
            ("RPM_OBSOLETES", "libbson < 1.28", "rpm -qp --obsoletes"),
            (
                "RPM_PROVIDES",
                self.valid_provides + "\nlibbson-1.0.so.0()(64bit)",
                "rpm -qp --provides",
            ),
        )
        for key, value, message in cases:
            with self.subTest(key=key):
                overrides = {"RPM_PROVIDES": self.valid_provides, key: value}
                self.assert_fails(self.run_guard("rpm", overrides), message)

    def test_rejects_missing_wrong_and_non_whole_metadata(self):
        for declaration in self.required_provides:
            with self.subTest(missing=declaration):
                provides = "\n".join(
                    item for item in self.required_provides if item != declaration
                )
                self.assert_fails(
                    self.run_guard("rpm", {"RPM_PROVIDES": provides}),
                    f"does not Provide '{declaration}'",
                )

        cases = (
            self.valid_provides.replace("1.28.0", "1.27.0"),
            self.valid_provides.replace(
                "bundled(libbson) = 1.28.0", "notbundled(libbson) = 1.28.0"
            ),
        )
        for provides in cases:
            with self.subTest(provides=provides):
                self.assert_fails(
                    self.run_guard("rpm", {"RPM_PROVIDES": provides}), "libbson"
                )

    def test_rejects_empty_build_and_query_failures(self):
        self.assert_fails(
            self.run_guard("rpm", create_package=False), "rpmbuild produced no RPM"
        )
        cases = (
            ("RPM_LIST_STATUS", "--list"),
            ("RPM_PROVIDES_STATUS", "--provides"),
            ("RPM_REQUIRES_STATUS", "--requires"),
            ("RPM_CONFLICTS_STATUS", "--conflicts"),
            ("RPM_OBSOLETES_STATUS", "--obsoletes"),
        )
        for status, query in cases:
            with self.subTest(query=query):
                self.assert_fails(
                    self.run_guard(
                        "rpm",
                        {
                            "RPM_PROVIDES": self.valid_provides,
                            status: "44",
                        },
                    ),
                    f"rpm -qp {query} failed",
                )


class DebGuardTests(GuardTestCase):
    valid = {
        "DPKG_SBU": "intelrdfpmath (= 2.0u3-1)",
        "DPKG_BUNDLED": "libbson (= 1.28.0), pcre2 (= 10.42)",
    }

    def run_deb(self, **overrides):
        return self.run_guard("deb", {**self.valid, **overrides})

    def test_valid_control(self):
        self.assert_passes(self.run_deb())

    def test_rejects_libbson_file_and_runtime_relationship(self):
        cases = (
            ("DPKG_CONTENTS", "./usr/lib/libbson-1.0.so.0", "dpkg-deb -c"),
            ("DPKG_CONTROL", "Depends: libbson-1.0-0", "dpkg-deb -f"),
        )
        for key, value, message in cases:
            with self.subTest(key=key):
                self.assert_fails(self.run_deb(**{key: value}), message)

    def test_rejects_missing_wrong_and_non_whole_metadata(self):
        cases = (
            ("DPKG_SBU", "", "'intelrdfpmath (= 2.0u3-1)' in Static-Built-Using"),
            ("DPKG_SBU", "intelrdfpmath (= 2.0u3)", "'intelrdfpmath (= 2.0u3-1)'"),
            ("DPKG_BUNDLED", "pcre2 (= 10.42)", "'libbson (= 1.28.0)' in Bundled"),
            ("DPKG_BUNDLED", "libbson (= 1.28.0)", "'pcre2 (= 10.42)' in Bundled"),
            ("DPKG_BUNDLED", "libbson (= 1.27.0), pcre2 (= 10.42)", "'libbson (= 1.28.0)'"),
            ("DPKG_BUNDLED", "notlibbson (= 1.28.0), pcre2 (= 10.42)", "'libbson (= 1.28.0)'"),
        )
        for key, value, message in cases:
            with self.subTest(**{key: value}):
                self.assert_fails(self.run_deb(**{key: value}), message)

    def test_rejects_empty_build_and_package_query_failures(self):
        self.assert_fails(
            self.run_guard("deb", create_package=False), "debuild produced no .deb"
        )
        cases = (
            ("DPKG_CONTENTS_STATUS", "dpkg-deb failed"),
            ("DPKG_CONTROL_STATUS", "dpkg-deb failed"),
            ("DPKG_AUTO_STATUS", "Auto-Built-Package failed"),
            ("DPKG_SBU_STATUS", "Static-Built-Using failed"),
            ("DPKG_BUNDLED_STATUS", "Bundled failed"),
        )
        for key, message in cases:
            with self.subTest(key=key):
                self.assert_fails(self.run_deb(**{key: "45"}), message)

    def test_allows_auto_built_debug_package_without_metadata(self):
        self.assert_passes(
            self.run_guard(
                "deb",
                {
                    "DEB_NAME": "documentdb-dbgsym.deb",
                    "DPKG_AUTO": "debug-symbols",
                    "DPKG_SBU_STATUS": "46",
                    "DPKG_BUNDLED_STATUS": "46",
                },
            )
        )


if __name__ == "__main__":
    unittest.main()
