"""The two shared authorities behind every DocumentDB settings block.

render_documentdb_pg_conf spells the settings and
documentdb_required_preload_libraries owns the required library set; a failure
in either must stop documentdb-setup, documentdb-tune and the sample generator.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = OSS_ROOT / "documentdb-local" / "scripts"
PACKAGING = OSS_ROOT / "packaging"
TOOLS_LIB = SCRIPTS_DIR / "documentdb-tools-lib.sh"
PRELOAD_LIB = OSS_ROOT / "scripts" / "preload_libraries.sh"
GENERATOR = PACKAGING / "postgresql-tools" / "generate-conf-sample.sh"
SAMPLE = PACKAGING / "postgresql-tools" / "documentdb.conf.sample"
DOCKERFILE = PACKAGING / "gateway" / "docker" / "Dockerfile_documentdb_local"

# The library's header states that a sourcing script must define die() before
# the first helper call.
DIE = 'die() { echo "$*" >&2; exit 1; }\n'

# _stage(): copy the real preload authority rather than staging none or a stub.
_REAL = object()


def _bash(snippet):
    return subprocess.run(["bash", "-c", snippet], stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=60)


def _stage(td, preload=_REAL):
    """Stage the library where only the copy placed here can answer, and return
    its path. Nested below the temp root so the second candidate,
    `<here>/../../scripts/preload_libraries.sh`, stays inside the temp tree
    rather than escaping to /scripts."""
    stage = Path(td) / "usr" / "share" / "documentdb-test" / "scripts"
    stage.mkdir(parents=True)
    shutil.copy2(TOOLS_LIB, stage / TOOLS_LIB.name)
    if preload is _REAL:
        shutil.copy2(PRELOAD_LIB, stage / "preload_libraries.sh")
    elif preload is not None:
        (stage / "preload_libraries.sh").write_text(preload, encoding="utf-8")
    return stage / TOOLS_LIB.name


class SharedRendererTests(unittest.TestCase):
    """One renderer, so the three consumers cannot drift on which settings
    DocumentDB writes or how they are spelled."""

    def _render(self, args):
        return _bash(DIE + f'source "{TOOLS_LIB}"\n'
                     f'render_documentdb_pg_conf {args}')

    def test_generated_sample_matches_its_generator(self):
        r = _bash(f'"{GENERATOR}"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            r.stdout, SAMPLE.read_text(encoding="utf-8"),
            "documentdb.conf.sample is stale; regenerate it with "
            "oss/packaging/postgresql-tools/generate-conf-sample.sh")

    def test_omitted_options_omit_their_lines(self):
        """Omitting an option is not defaulting it: an empty --toast means
        "leave the server's own setting alone", which is how an unsupported lz4
        build and an explicit `--toast-compression default` both arrive."""
        r = self._render('--preload "pg_cron" --toast ""')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("default_toast_compression", r.stdout)
        self.assertNotIn("documentdb.localhost_connection_string", r.stdout)
        self.assertNotIn("rum_library_load_option", r.stdout)

    def test_extended_rum_overlay_is_opt_in(self):
        r = self._render('--preload "pg_cron" --extended-rum true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("documentdb.rum_library_load_option", r.stdout)
        self.assertIn("documentdb.alternate_index_handler_name", r.stdout)

    def test_values_that_would_break_quoting_are_rejected(self):
        """Every rendered value lands inside single quotes in postgresql.conf."""
        for bad in ("a'b", "a\\\\b"):
            with self.subTest(value=bad):
                r = self._render(f'--preload "{bad}"')
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(r.stdout, "")

    def test_bad_invocations_are_rejected(self):
        """A block with no shared_preload_libraries is not representable, so
        --preload is required and must be non-empty."""
        for label, args in (
            ("unknown option", "--nope x"),
            ("option without a value", "--preload"),
            ("no --preload", '--toast lz4'),
            ("empty --preload", '--preload ""'),
        ):
            with self.subTest(case=label):
                r = self._render(args)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(r.stdout, "")


class PreloadAuthorityTests(unittest.TestCase):
    """The required library set has one owner, the extension's
    preload_libraries.sh. The host tools derive it through
    documentdb_required_preload_libraries and fail closed without it."""

    def _required(self, with_rum, preload=_REAL):
        with tempfile.TemporaryDirectory() as td:
            lib = _stage(td, preload)
            return _bash(DIE + f'source "{lib}"\n'
                         f'documentdb_required_preload_libraries {with_rum}')

    def _authority(self, with_rum):
        r = _bash(f'. "{PRELOAD_LIB}"\nGetDocumentDBBasePreloadLibraries '
                  + ("--rum" if with_rum == "true" else ""))
        self.assertEqual(r.returncode, 0, r.stderr)
        return [item.strip() for item in r.stdout.split(",") if item.strip()]

    def test_required_set_comes_from_the_extension_helper(self):
        for with_rum in ("false", "true"):
            with self.subTest(extended_rum=with_rum):
                r = self._required(with_rum)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.splitlines(),
                                 self._authority(with_rum))

    def test_a_trailing_empty_field_is_ignored(self):
        """The helper's answer is comma-joined, so a trailing comma yields an
        empty field; it must not become a library name or a failure."""
        r = self._required("false", preload=(
            "GetDocumentDBBasePreloadLibraries() { "
            'echo "pg_cron, pg_documentdb_core, pg_documentdb, "; }\n'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(),
                         ["pg_cron", "pg_documentdb_core", "pg_documentdb"])

    def test_missing_authority_fails_the_caller(self):
        """No authority must stop the caller, not empty the required set: a
        managed block with no shared_preload_libraries line is a cluster that
        silently never preloads DocumentDB."""
        with tempfile.TemporaryDirectory() as td:
            lib = _stage(td, preload=None)
            r = _bash(DIE + f'source "{lib}"\nHAS_EXTENDED_RUM=false\n'
                      'merge_shared_preload_libraries ""')
        self.assertNotEqual(r.returncode, 0,
                            "a missing preload authority must not return success")
        self.assertEqual(r.stdout, "")


class RendererFailsClosedTests(unittest.TestCase):
    """A renderer failure must reach the caller. Both callers run inside a
    command substitution, where bash drops errexit, so only an explicit
    `|| die` keeps a failed render from yielding a block with no
    shared_preload_libraries line."""

    @staticmethod
    def _function_body(path, name):
        """Sliced by line, because these files are long enough that a
        backtracking pattern over them is a hazard in its own right."""
        lines = path.read_text(encoding="utf-8").splitlines()
        start = lines.index(f"{name}() {{")
        return "\n".join(lines[start:lines.index("}", start) + 1])

    _PRELUDE = ('set -euo pipefail\n' + DIE + f'source "{TOOLS_LIB}"\n'
                'PG_PORT=9718\nPG_SOCKET_DIR=/run/documentdb-local/postgresql\n'
                'TOAST_COMPRESSION=lz4\nHAS_EXTENDED_RUM=false\n')

    def _build_block(self, preload):
        body = self._function_body(SCRIPTS_DIR / "documentdb-setup.sh",
                                   "build_postgres_conf_block")
        return _bash(
            self._PRELUDE +
            'config_file=/etc/postgresql/17/main/postgresql.conf\n'
            f'{body}\n'
            f'out="$(build_postgres_conf_block {preload} "on")"\n'
            'echo "CALLER-CONTINUED"\n'
            'printf %s "$out"\n')

    def _tune_block(self, preload):
        body = self._function_body(SCRIPTS_DIR / "documentdb-tune.sh",
                                   "build_config_block")
        return _bash(
            self._PRELUDE +
            # Lives outside the sliced function; stub it so the slice renders a
            # realistic --localhost-conn instead of an empty one.
            'resolve_localhost_connection() { printf "host=%s port=%s" '
            '"$PG_SOCKET_DIR" "$PG_PORT"; }\n'
            f'{body}\n'
            f'out="$(build_config_block {preload})"\n'
            'echo "CALLER-CONTINUED"\n'
            'printf %s "$out"\n')

    def test_a_rejected_value_stops_the_caller(self):
        # A backslash is one of the characters the renderer refuses, and it can
        # reach here: merged_preload is built from the operator's existing
        # shared_preload_libraries line.
        r = self._build_block(r'"pg_cron, weird\lib"')
        self.assertNotEqual(r.returncode, 0,
                            "the renderer's failure must reach the caller")
        self.assertNotIn("CALLER-CONTINUED", r.stdout,
                         "documentdb-setup must not go on to write a block")

    def test_an_accepted_value_renders_normally(self):
        r = self._build_block('"pg_cron, pg_documentdb_core, pg_documentdb"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("CALLER-CONTINUED", r.stdout)
        self.assertIn("shared_preload_libraries", r.stdout)
        self.assertIn("port = 9718", r.stdout)
        self.assertIn("ssl = on", r.stdout)

    def test_documentdb_tune_also_stops_on_a_rejected_value(self):
        """documentdb-tune's block ends with the renderer, so its status
        propagates today -- but that is an accident of ordering. Assert the
        behaviour, not the ordering."""
        r = self._tune_block(r'"pg_cron, weird\lib"')
        self.assertNotEqual(r.returncode, 0,
                            "documentdb-tune must not write a block the "
                            "renderer refused to produce")
        self.assertNotIn("CALLER-CONTINUED", r.stdout)

    def test_documentdb_tune_renders_an_accepted_value(self):
        r = self._tune_block('"pg_cron, pg_documentdb_core, pg_documentdb"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("CALLER-CONTINUED", r.stdout)
        self.assertIn(
            "shared_preload_libraries = 'pg_cron, pg_documentdb_core, "
            "pg_documentdb'", r.stdout)

    def test_the_sample_generator_stops_when_the_authority_fails(self):
        """The same shape in an argument position, which errexit also hides."""
        for label, stub in (
            ("fails when called",
             "GetDocumentDBBasePreloadLibraries() { return 1; }\n"),
            ("answers empty", "GetDocumentDBBasePreloadLibraries() { :; }\n"),
        ):
            with self.subTest(authority=label), \
                    tempfile.TemporaryDirectory() as td:
                lib = _stage(td, preload=stub)
                r = _bash(f'"{GENERATOR}" --sample "{SAMPLE}" '
                          f'--tools-lib "{lib}"')
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(
                    r.stdout, "",
                    "no sample may be written when the preload list is unknown")


class RenderedValueTests(unittest.TestCase):
    """documentdb-setup compares the live server against the values the
    renderer writes, read back through documentdb_rendered_value, so the
    wizard carries no copy of them."""

    def _value(self, name, block):
        return _bash(f'. "{TOOLS_LIB}"; documentdb_rendered_value "{name}" <<< "{block}"')

    def test_reads_the_renderers_value_with_quotes_stripped(self):
        block = ("shared_preload_libraries = 'pg_cron, pg_documentdb'\n"
                 "cron.database_name = 'postgres'\n"
                 "documentdb.enableBackgroundWorker = true\n")
        for name, expected in (("cron.database_name", "postgres"),
                               ("documentdb.enableBackgroundWorker", "true"),
                               ("shared_preload_libraries", "pg_cron, pg_documentdb")):
            with self.subTest(name=name):
                r = self._value(name, block)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout, expected)

    def test_a_setting_the_renderer_does_not_write_is_a_failure(self):
        r = self._value("documentdb.rum_library_load_option",
                        "cron.database_name = 'postgres'\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_bool_normalization_covers_every_postgres_spelling(self):
        cases = {"on": "on", "TRUE": "on", "yes": "on", "1": "on",
                 "off": "off", "False": "off", "no": "off", "0": "off",
                 "postgres": "postgres"}
        for raw, want in cases.items():
            with self.subTest(raw=raw):
                r = _bash(f'. "{TOOLS_LIB}"; documentdb_normalize_pg_bool "{raw}"')
                self.assertEqual((r.returncode, r.stdout), (0, want), r.stderr)

    def test_wizard_table_carries_names_only(self):
        script = (SCRIPTS_DIR / "documentdb-setup.sh").read_text(encoding="utf-8")
        table = re.search(r"managed_restart_gucs=\((.*?)\)", script, re.S)
        self.assertIsNotNone(table, "documentdb-setup no longer has managed_restart_gucs")
        rows = re.findall(r'"([^"]+)"', table.group(1))
        rows += re.findall(r'managed_restart_gucs\+=\("([^"]+)"\)', script)
        self.assertTrue(rows)
        for row in rows:
            with self.subTest(row=row):
                self.assertRegex(row, r"^[A-Za-z_.]+\|[01]$",
                                 "a restart-GUC row must be name|is_bool; the "
                                 "expected value comes from the renderer")
        self.assertIn('documentdb_rendered_value "${guc_name}"', script)
        # Every listed name is one the renderer actually writes, so the wizard
        # cannot die at run time on a name that has no rendered value.
        r = _bash(f'. "{TOOLS_LIB}"; render_documentdb_pg_conf --preload x --extended-rum true')
        self.assertEqual(r.returncode, 0, r.stderr)
        for row in rows:
            name = row.split("|")[0]
            with self.subTest(name=name):
                self.assertRegex(r.stdout, rf"(?m)^{re.escape(name)} = ")


class GatewayJsonStripFieldsTests(unittest.TestCase):
    """The connection fields deleted from the gateway JSON are spelled three
    times: documentdb-setup's per-major cleanup, and the jq and python
    branches of the package build's strip script, which cannot source the
    library. None can read another, so the three are held equal here."""

    STRIP = PACKAGING / "gateway" / "strip-setup-config.sh"
    SETUP = SCRIPTS_DIR / "documentdb-setup.sh"

    @staticmethod
    def _jq_fields(text, where):
        m = re.search(r"jq '\s*del\(([^)]*)\)'", text)
        assert m, f"{where} lost its jq del() filter"
        return {f.strip().lstrip(".") for f in m.group(1).split(",")}

    def test_the_three_lists_agree(self):
        strip = self.STRIP.read_text(encoding="utf-8")
        py = re.search(r"strip = \{([^}]*)\}", strip, re.S)
        self.assertIsNotNone(py, "strip-setup-config.sh lost its python strip set")
        lists = {
            "strip-setup-config.sh (jq)": self._jq_fields(strip, "strip-setup-config.sh"),
            "strip-setup-config.sh (python)": set(re.findall(r'"([A-Za-z]+)"', py.group(1))),
            "documentdb-setup.sh": self._jq_fields(self.SETUP.read_text(encoding="utf-8"), "documentdb-setup.sh"),
        }
        reference = lists["strip-setup-config.sh (jq)"]
        self.assertEqual(len(reference), 6)
        for where, fields in lists.items():
            with self.subTest(where=where):
                self.assertEqual(fields, reference)


class ImageDefaultPinTests(unittest.TestCase):
    """documentdb_local_settings.sh owns every default of the container image.
    The in-image scripts read it; the only copy is the Dockerfile ENV block,
    kept so `docker inspect` shows the defaults, and it is held equal here.
    The two values the host tools also use are held equal to the library."""

    SETTINGS = SCRIPTS_DIR / "documentdb_local_settings.sh"
    ENTRYPOINT = SCRIPTS_DIR / "emulator_entrypoint.sh"
    READERS = (ENTRYPOINT, SCRIPTS_DIR / "healthcheck.sh",
               SCRIPTS_DIR / "init_documentdb_data.sh",
               SCRIPTS_DIR / "documentdb_prepare_data_directory.sh")

    @classmethod
    def _table(cls):
        """{ENV_VAR: (flag, default, type)} parsed from the settings rows."""
        rows = re.findall(r'(?m)^\s*"(--[^|"]+)\|([A-Z_]+)\|([^|"]*)\|([^|"]+)\|[^"]*"',
                          cls.SETTINGS.read_text(encoding="utf-8"))
        return {var: (flag, default, typ) for flag, var, default, typ in rows}

    @staticmethod
    def _env_block():
        text = re.sub(r"\\\n\s*", " ", DOCKERFILE.read_text(encoding="utf-8"))
        block = re.search(r'(?m)^ENV CERT_PATH=.*$', text)
        assert block, "the Dockerfile ENV block starting with CERT_PATH is gone"
        return dict(re.findall(r'\b([A-Z_]+)="([^"]*)"', block.group(0)))

    def test_table_is_well_formed(self):
        table = self._table()
        self.assertGreaterEqual(len(table), 17)
        for var, (flag, default, typ) in table.items():
            with self.subTest(var=var):
                self.assertRegex(typ, r"^(uint|bool|string|enum:[A-Za-z0-9_,]+)$")
                if default and typ.startswith("enum:"):
                    self.assertIn(default, typ[len("enum:"):].split(","))

    # Deliberately absent from the ENV block: the legacy password must not be
    # baked into an inspectable layer, and the TOAST default is applied by the
    # entrypoint, which treats a set variable as an explicit request.
    NOT_IN_ENV = {"PASSWORD", "DOCUMENTDB_TOAST_COMPRESSION"}

    def test_dockerfile_env_mirrors_the_table(self):
        table = self._table()
        env = self._env_block()
        for var, (flag, default, typ) in table.items():
            if not default or var in self.NOT_IN_ENV:
                continue
            with self.subTest(var=var):
                self.assertIn(var, env, f"{var} is missing from the Dockerfile ENV mirror")
                self.assertEqual(env[var], default, f"Dockerfile ENV {var} disagrees with the table")

    def test_shared_values_match_the_library(self):
        table = self._table()
        lib = TOOLS_LIB.read_text(encoding="utf-8")
        for var, lib_name in (("DOCUMENTDB_PORT", "DOCUMENTDB_DEFAULT_GATEWAY_PORT"),
                              ("DOCUMENTDB_TOAST_COMPRESSION", "DOCUMENTDB_DEFAULT_TOAST_COMPRESSION")):
            with self.subTest(var=var):
                m = re.search(rf'(?m)^{lib_name}="?([^"\n]+?)"?$', lib)
                self.assertIsNotNone(m, f"{lib_name} is no longer a plain assignment in the library")
                self.assertEqual(table[var][1], m.group(1), f"{var} disagrees with {lib_name}")

    def test_readers_carry_no_copy_of_a_table_default(self):
        table = self._table()
        for path in self.READERS:
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                self.assertIn("documentdb_local_settings.sh", text, f"{path.name} does not source the table")
                for var, (flag, default, typ) in table.items():
                    if not default:
                        continue
                    # A `${VAR:-literal}` fallback or a bare `VAR="literal"`
                    # assignment of the default would be a second spelling.
                    self.assertNotRegex(text, rf"\$\{{{var}:-{re.escape(default)}\}}",
                                        f"{path.name} spells the {var} default inline")
                    self.assertNotRegex(text, rf'(?m)^{var}="{re.escape(default)}"$',
                                        f"{path.name} assigns the {var} default inline")

    def test_lookup_helpers_answer_from_the_table(self):
        r = _bash(f'. "{self.SETTINGS}"; documentdb_local_setting_default POSTGRESQL_PORT; echo; '
                  f'documentdb_local_setting_allowed TLS_MODE; echo; '
                  f'documentdb_local_setting_row_by_flag --username | cut -d"|" -f2; '
                  f'documentdb_local_setting_default NO_SUCH_SETTING && echo unexpected; true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split("\n")[:3],
                         [self._table()["POSTGRESQL_PORT"][1], "disabled, allowTLS, requireTLS", "USERNAME"])
        self.assertNotIn("unexpected", r.stdout)


if __name__ == "__main__":
    unittest.main()
