"""The documentdb-local usage-telemetry emitter (usage_telemetry.sh).

Covers what the container is allowed to send and when it must stay silent:
configuration resolution, the default-on/opt-out precedence, the exact payload
fields, and that neither user data nor credentials can reach the endpoint.
"""

import os
import re
import subprocess
import tempfile
import unittest
import urllib.parse
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = OSS_ROOT / "documentdb-local" / "scripts"
EMITTER = SCRIPTS_DIR / "usage_telemetry.sh"
SETTINGS = SCRIPTS_DIR / "documentdb_local_settings.sh"
ENTRYPOINT = SCRIPTS_DIR / "emulator_entrypoint.sh"
PRIVACY = OSS_ROOT / "documentdb-local" / "PRIVACY.md"
DOCKERFILE = (OSS_ROOT / "packaging" / "gateway" / "docker"
              / "Dockerfile_documentdb_local")

# Stand-in for curl that records the URL it was asked to fetch and succeeds,
# so tests observe exactly what would leave the container without any network.
CURL_STUB = (
    "#!/bin/sh\n"
    'for arg in "$@"; do\n'
    '    case "$arg" in\n'
    '        http*) echo "$arg" >> "$CURL_LOG" ;;\n'
    "    esac\n"
    "done\n"
    "exit 0\n"
)


class _EmitterCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.curl_log = self.root / "curl.log"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text(CURL_STUB, encoding="utf-8")
        curl.chmod(0o755)
        self.bin_dir = bin_dir
        self.version_file = self.root / "version.txt"
        self.version_file.write_text(
            "0.109-0 (commit abc1234, built 2026-09-22, postgresql 17)\n", encoding="utf-8")

    def _env(self, **overrides):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["CURL_LOG"] = str(self.curl_log)
        env["USAGE_TELEMETRY_VERSION_FILE"] = str(self.version_file)
        for key in ("NO_ANALYTICS", "DO_NOT_TRACK",
                    "DOCUMENTDB_USAGE_TELEMETRY",
                    "DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT",
                    "DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S",
                    # The suite itself usually runs on a build agent, where the
                    # emitter is meant to stay silent. Clear the CI markers so
                    # these tests exercise the deployment path; the CI skip has
                    # its own tests that set them back.
                    "CI", "GITHUB_ACTIONS", "TF_BUILD"):
            env.pop(key, None)
        env.update({k: str(v) for k, v in overrides.items()})
        return env

    def _bash(self, snippet, timeout=30, **overrides):
        return subprocess.run(["bash", "-c", snippet], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=timeout,
                              env=self._env(**overrides))

    def _sourced(self, snippet, **overrides):
        return self._bash(f'. "{EMITTER}"\n{snippet}', **overrides)

    def _sent(self):
        """The query parameters of every request, in order."""
        if not self.curl_log.exists():
            return []
        return [dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(line).query))
                for line in self.curl_log.read_text(encoding="utf-8").splitlines() if line]


class ConfigurationTests(_EmitterCase):
    def test_enabled_by_default(self):
        self.assertEqual(self._sourced("usage_telemetry_enabled && echo on").stdout.strip(), "on")

    def test_disabled_by_the_enable_variable(self):
        r = self._sourced("usage_telemetry_enabled || echo off", DOCUMENTDB_USAGE_TELEMETRY="false")
        self.assertEqual(r.stdout.strip(), "off")

    def test_every_ordinary_off_spelling_disables(self):
        """An opt-out a user actually types has to work. Honoring only the
        exact string "false" would leave someone who wrote 0/no/off believing
        they had opted out while telemetry kept running."""
        for value in ("false", "FALSE", "False", "0", "no", "NO", "n",
                      "off", "Off", "disable", "disabled"):
            with self.subTest(value=value):
                r = self._sourced("usage_telemetry_enabled || echo off",
                                  DOCUMENTDB_USAGE_TELEMETRY=value)
                self.assertEqual(r.stdout.strip(), "off")

    def test_every_ordinary_on_spelling_enables(self):
        for value in ("true", "TRUE", "1", "yes", "y", "on", "enabled"):
            with self.subTest(value=value):
                r = self._sourced("usage_telemetry_enabled && echo on",
                                  DOCUMENTDB_USAGE_TELEMETRY=value)
                self.assertEqual(r.stdout.strip(), "on")

    def test_an_unrecognized_value_does_not_track(self):
        # The setting is an off switch, so an unparsable value must not be
        # read as consent.
        r = self._sourced("usage_telemetry_enabled || echo off",
                          DOCUMENTDB_USAGE_TELEMETRY="maybe")
        self.assertEqual(r.stdout.strip(), "off")

    def test_skipped_in_ci(self):
        """A build agent is not a deployment, and nobody reads the startup
        notice there."""
        for var in ("CI", "GITHUB_ACTIONS", "TF_BUILD"):
            with self.subTest(var=var):
                r = self._sourced("usage_telemetry_enabled || echo off",
                                  DOCUMENTDB_USAGE_TELEMETRY="true", **{var: "true"})
                self.assertEqual(r.stdout.strip(), "off")

    def test_ci_skip_sends_nothing(self):
        r = self._bash(f'timeout 10 bash "{EMITTER}"', CI="true")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._sent(), [])

    def test_standard_opt_out_wins_over_an_explicit_enable(self):
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            with self.subTest(var=var):
                r = self._sourced("usage_telemetry_enabled || echo off",
                                  DOCUMENTDB_USAGE_TELEMETRY="true", **{var: "1"})
                self.assertEqual(r.stdout.strip(), "off")

    def test_a_falsey_opt_out_value_does_not_opt_out(self):
        # NO_ANALYTICS=0 is the documented "yes, you may track" spelling.
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            with self.subTest(var=var):
                r = self._sourced("usage_telemetry_enabled && echo on", **{var: "0"})
                self.assertEqual(r.stdout.strip(), "on")

    def test_a_set_but_empty_opt_out_still_opts_out(self):
        """Presence is the signal, so a variable that is set to nothing is
        still an opt-out. This is the realistic shape: `docker run -e
        NO_ANALYTICS` with no value passes the variable through empty, and
        `NO_ANALYTICS=` in a compose file does the same. Reading these with
        "${VAR:-}" would collapse them into "unset" and track an operator who
        had named the opt-out explicitly."""
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            with self.subTest(var=var):
                r = self._sourced("usage_telemetry_enabled || echo off", **{var: ""})
                self.assertEqual(r.stdout.strip(), "off")

    def test_a_set_but_empty_opt_out_sends_nothing(self):
        # The predicate above must reach the wire: an empty opt-out emits
        # no event at all.
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            with self.subTest(var=var):
                self.curl_log.write_text("", encoding="utf-8")
                r = self._bash(f'timeout 10 bash "{EMITTER}"', **{var: ""})
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self._sent(), [])

    def test_unset_opt_out_variables_leave_telemetry_on(self):
        # Control for the two tests above: "set to empty" must be
        # distinguishable from "absent", or the opt-out would be unconditional
        # and the default-on behavior would never apply.
        r = self._sourced("usage_telemetry_enabled && echo on")
        self.assertEqual(r.stdout.strip(), "on")

    def test_an_unparseable_opt_out_value_still_opts_out(self):
        """These variables are asymmetric on purpose. Only an explicit off
        spelling means "you may track me"; anything else is honored. Nobody
        sets NO_ANALYTICS hoping to be tracked, so resolving an unparseable
        value to "keep tracking" would discard the one intent it can have.
        The whitespace cases are the realistic ones: `NO_ANALYTICS=1 ` in a
        .env file or a quoted compose value must not silently re-enable
        tracking."""
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            for value in ("garbage", "2", "-1", "TRUE!", "1 ", " 1", "yes please"):
                with self.subTest(var=var, value=value):
                    r = self._sourced("usage_telemetry_enabled || echo off",
                                      **{var: value})
                    self.assertEqual(r.stdout.strip(), "off")

    def test_an_unparseable_opt_out_value_sends_nothing(self):
        # The resolution above must actually reach the wire, not just the
        # predicate: a malformed opt-out emits no event at all.
        for var in ("NO_ANALYTICS", "DO_NOT_TRACK"):
            with self.subTest(var=var):
                self.curl_log.write_text("", encoding="utf-8")
                r = self._bash(f'timeout 10 bash "{EMITTER}"', **{var: "garbage"})
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self._sent(), [])

    def test_endpoint_default_and_override(self):
        # Must be the package's configured event-collection ROUTE, matched
        # literally. Any other path 404s, and a fire-and-forget emitter cannot
        # tell that from success -- the failure shows up only as absent data.
        self.assertEqual(self._sourced("usage_telemetry_endpoint").stdout,
                         "https://documentdb.gateway.scarf.sh/telemetry")
        r = self._sourced("usage_telemetry_endpoint",
                          DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT="http://localhost:9/sink")
        self.assertEqual(r.stdout, "http://localhost:9/sink")

    def test_interval_default_override_and_bad_values(self):
        self.assertEqual(self._sourced("usage_telemetry_interval").stdout, "3600")
        self.assertEqual(
            self._sourced("usage_telemetry_interval",
                          DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S="900").stdout, "900")
        # A non-numeric value falls back rather than failing the container.
        self.assertEqual(
            self._sourced("usage_telemetry_interval",
                          DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S="soon").stdout, "3600")
        # Below the floor the loop would busy-spin against the endpoint.
        self.assertEqual(
            self._sourced("usage_telemetry_interval",
                          DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S="1").stdout, "60")

    def test_version_is_the_leading_token_of_the_version_file(self):
        self.assertEqual(self._sourced("usage_telemetry_version").stdout, "0.109-0")

    def test_a_missing_version_file_is_not_fatal(self):
        r = self._sourced("usage_telemetry_version; echo rc=$?",
                          USAGE_TELEMETRY_VERSION_FILE=str(self.root / "absent.txt"))
        self.assertEqual(r.stdout.strip(), "rc=0")


class PayloadTests(_EmitterCase):
    def test_launch_event_carries_exactly_the_documented_fields(self):
        r = self._bash(f'timeout 10 bash "{EMITTER}" >/dev/null 2>&1; true')
        self.assertEqual(r.returncode, 0, r.stderr)
        sent = self._sent()
        self.assertTrue(sent, "no launch event was emitted")
        self.assertEqual(set(sent[0]),
                         {"event", "version", "platform", "arch", "db_system"})
        self.assertEqual(sent[0]["event"], "emulator_launch")
        self.assertEqual(sent[0]["version"], "0.109-0")
        self.assertEqual(sent[0]["db_system"], "documentdb")
        # `platform` (not `os`) is the name the collector recognizes for its
        # built-in breakdowns, and its recognized values are lowercase.
        self.assertEqual(sent[0]["platform"], os.uname().sysname.lower())
        self.assertEqual(sent[0]["arch"], os.uname().machine)

    def test_heartbeat_follows_the_launch_event(self):
        # Sourced so the interval floor can be relaxed for the test; the
        # shipped floor is exercised by test_interval_default_override_and_bad_values.
        r = self._bash(
            f'. "{EMITTER}"\n'
            "USAGE_TELEMETRY_MIN_INTERVAL_S=1\n"
            "usage_telemetry_main >/dev/null 2>&1 &\n"
            "sleep 4\n"
            "kill %1 2>/dev/null; true\n",
            DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        events = [event["event"] for event in self._sent()]
        self.assertEqual(events[0], "emulator_launch")
        self.assertIn("emulator_heartbeat", events[1:])

    def test_values_are_url_encoded(self):
        r = self._sourced('usage_telemetry_urlencode "a b&c=d/e"')
        self.assertEqual(r.stdout, "a%20b%26c%3Dd%2Fe")

    def test_nothing_is_sent_when_disabled_or_opted_out(self):
        for overrides in ({"DOCUMENTDB_USAGE_TELEMETRY": "false"}, {"DO_NOT_TRACK": "1"},
                          {"NO_ANALYTICS": "1"}):
            with self.subTest(**overrides):
                self.curl_log.unlink(missing_ok=True)
                r = self._bash(f'timeout 10 bash "{EMITTER}"', **overrides)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self._sent(), [])
                self.assertEqual(r.stdout, "")

    def test_no_user_identifier_or_credential_can_reach_the_endpoint(self):
        # Everything a deployment might name is exported; none of it is read.
        secrets = {"PASSWORD": "s3cret-pw", "USERNAME": "alice",
                   "DOCUMENTDB_PORT": "10260", "OWNER": "alice"}
        self._bash(f'timeout 10 bash "{EMITTER}" >/dev/null 2>&1; true', **secrets)
        payload = self.curl_log.read_text(encoding="utf-8")
        for value in secrets.values():
            self.assertNotIn(value, payload)


class WiringTests(unittest.TestCase):
    """The emitter is only useful if the image declares, starts and stops it."""

    def test_the_setting_is_declared_once_in_the_table(self):
        rows = re.findall(r'(?m)^\s*"(--[^|"]+)\|DOCUMENTDB_USAGE_TELEMETRY\|([^|"]*)\|([^|"]+)\|',
                          SETTINGS.read_text(encoding="utf-8"))
        # "boolish", not "bool": a strict bool aborts the container on any
        # spelling but true/false, which would make opting out a crash.
        self.assertEqual(rows, [("--usage-telemetry", "true", "boolish")])

    def test_the_entrypoint_starts_and_reaps_the_emitter(self):
        text = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn("usage_telemetry.sh", text)
        self.assertIn("--disable-usage-telemetry", text)
        # Started in the background and killed by cleanup(), so `docker stop`
        # does not leave a heartbeat loop behind.
        self.assertRegex(text, r'bash "\$telemetry_script" &\s+USAGE_TELEMETRY_PID=\$!')
        self.assertRegex(text, r'kill \$USAGE_TELEMETRY_PID')

    def test_the_bare_disable_flag_turns_the_setting_off(self):
        text = ENTRYPOINT.read_text(encoding="utf-8")
        block = re.search(r"--disable-usage-telemetry\)(.*?);;", text, re.S)
        self.assertIsNotNone(block, "the --disable-usage-telemetry case is gone")
        self.assertIn("export DOCUMENTDB_USAGE_TELEMETRY=false", block.group(1))

    def test_no_user_facing_name_carries_the_vendor_name(self):
        """The analytics provider is an implementation detail. Every name an
        operator types or that appears in the shipped scripts is named for the
        product: NO_ANALYTICS and DOCUMENTDB_USAGE_TELEMETRY. No
        vendor-specific variable is read at all, so the provider can be
        changed without touching anything an operator has configured."""
        for path in (SETTINGS, EMITTER, ENTRYPOINT, PRIVACY):
            names = set(re.findall(r"\bSCARF_[A-Z_]+\b", path.read_text(encoding="utf-8")))
            with self.subTest(file=path.name):
                self.assertEqual(names, set())

    def test_the_projects_own_container_runs_disable_telemetry(self):
        """The emitter's CI check reads the container's environment, and
        `docker run` does not forward CI/GITHUB_ACTIONS/TF_BUILD from the host,
        so it never fires for a containerized pipeline run. Every place this
        repository starts the emulator detached must therefore disable
        collection explicitly, or the project's own test suites are counted as
        deployments and the adoption numbers measure our CI.

        A detached run that supplies emulator credentials is an emulator run;
        containers built for other purposes, such as the systemd and installer
        harnesses, do not carry the emitter and are not matched."""
        root = OSS_ROOT
        offenders = []
        for path in list(root.rglob("*.sh")) + list(root.rglob("*.yml")):
            if ".git" in path.parts:
                continue
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            for i, line in enumerate(lines):
                if "docker run -d" not in line or line.lstrip().startswith("#"):
                    continue
                # Gather the whole command, following line continuations.
                cmd, j = line, i
                while cmd.rstrip().endswith("\\") and j + 1 < len(lines):
                    j += 1
                    cmd += "\n" + lines[j]
                # Only runs that hand the emulator a credential are emulator runs.
                if not re.search(r"--password|-e\s+PASSWORD=|-e\s+USERNAME=", cmd):
                    continue
                # An echoed example in help text is not an invocation.
                if line.lstrip().startswith(("echo", 'echo "')):
                    continue
                if "DOCUMENTDB_USAGE_TELEMETRY=false" not in cmd:
                    offenders.append(f"{path.relative_to(root)}:{i + 1}")
        self.assertEqual(
            offenders, [],
            "these detached emulator runs would report themselves as real "
            "deployments; add -e DOCUMENTDB_USAGE_TELEMETRY=false:\n  "
            + "\n  ".join(offenders))

    def test_the_disclosure_does_not_promise_automatic_ci_exclusion(self):
        """The CI skip cannot be described as automatic, because the markers
        it reads are not forwarded into the container. Documenting it as
        automatic would tell operators their pipelines are excluded when they
        are not."""
        text = PRIVACY.read_text(encoding="utf-8")
        self.assertNotIn("Collection is skipped automatically", text)
        self.assertIn("does not forward variables", text)

    def test_the_disclosure_ships_inside_the_image(self):
        """Telemetry is on by default, so the document describing it must be
        readable from the container without network access: an air-gapped or
        offline deployment cannot open the GitHub copy, and that is exactly
        where an operator is most likely to want it before deciding whether
        to opt out. The emitter's startup notice names this path, so a
        dropped COPY would leave the notice pointing at a file that is not
        there."""
        doc = OSS_ROOT / "documentdb-local" / "PRIVACY.md"
        self.assertTrue(doc.is_file(), "documentdb-local/PRIVACY.md is missing")

        text = DOCKERFILE.read_text(encoding="utf-8")
        copy = re.search(r"(?m)^COPY\s+documentdb-local/PRIVACY\.md\s+(\S+)\s*$", text)
        self.assertIsNotNone(copy, "PRIVACY.md is not copied into the image")
        in_image = copy.group(1)

        # The notice must point at wherever the Dockerfile actually put it.
        emitter = EMITTER.read_text(encoding="utf-8")
        default = re.search(r'USAGE_TELEMETRY_PRIVACY_DOC="\$\{USAGE_TELEMETRY_PRIVACY_DOC:-([^}]+)\}"',
                            emitter)
        self.assertIsNotNone(default, "the emitter no longer records the doc path")
        self.assertEqual(default.group(1), in_image,
                         "the startup notice points somewhere the image does not ship")
        notice = [ln for ln in emitter.splitlines() if "Opt out with" in ln]
        self.assertTrue(notice, "the opt-out notice is gone")
        self.assertIn("USAGE_TELEMETRY_PRIVACY_DOC", notice[0],
                      "the startup notice stopped naming the in-image copy")

    def test_the_runtime_image_installs_curl(self):
        """The emitter degrades to a silent no-op without curl, so its absence
        would disable telemetry with no failing build and no error. The build
        stage's own curl does not reach the runtime image, and wget is purged
        there, so the runtime package list has to carry it."""
        text = DOCKERFILE.read_text(encoding="utf-8")
        runtime = re.search(r"FROM \$\{BASE_IMAGE\} AS runtime-base(.*?)^FROM ",
                            text, re.S | re.M)
        self.assertIsNotNone(runtime, "the runtime-base stage is gone")
        install = re.search(r"apt-get install -y --no-install-recommends\s*\\?\s*\n([^&]*?)&&",
                            runtime.group(1), re.S)
        self.assertIsNotNone(install, "the runtime-base package list is gone")
        self.assertIn("curl", install.group(1).split())
        # A later purge would undo the install just as silently.
        purge = re.search(r"apt-get purge -y ([^&\\\n]*)", runtime.group(1))
        if purge:
            self.assertNotIn("curl", purge.group(1).split())

    def test_opting_out_cannot_stop_the_container_from_starting(self):
        """End to end through the entrypoint's own validation: a user who
        writes the off switch in an ordinary spelling must get a container
        that boots, not one that aborts. CERT_PATH without KEY_FILE fails the
        cross-setting rule immediately after validation, so reaching that
        message proves the value was accepted."""
        for value in ("false", "0", "no", "FALSE", "off"):
            with self.subTest(value=value):
                env = dict(os.environ, CERT_PATH="/nope", PASSWORD="test-pw",
                           DOCUMENTDB_USAGE_TELEMETRY=value)
                env.pop("KEY_FILE", None)
                r = subprocess.run(["bash", str(ENTRYPOINT)], env=env,
                                   stdin=subprocess.DEVNULL, capture_output=True,
                                   text=True, timeout=60)
                self.assertNotIn("Invalid usage-telemetry", r.stdout + r.stderr)
                self.assertIn("Both CERT_PATH and KEY_FILE must be set together", r.stderr)


if __name__ == "__main__":
    unittest.main()
