"""
Tests for functional_gate.py recovery and split-universe verification.

Covers recover-and-gate (sequential re-run recovery of transient crash victims,
then gating on the merged report) and verify-split-universes (cross-leg
agreement of the collected test universe).
"""
import json
import os
import sys
from pathlib import Path

import pytest

# Add tools dir to path so we can import the module
sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from functional_gate import cmd_recover_and_gate  # noqa: E402


class TestRecoverAndGate:
    """recover-and-gate: sequential re-run recovery of transient crash victims,
    then gate (exit 1 on any residual) on the merged report."""

    GATE_PY = str(Path(__file__).parent.parent / "tools" / "functional_gate.py")
    PFX = "docdb_functional_tests/documentdb_tests/"

    def _base(self, tmp_path, outcomes):
        rep = {"tests": [{"nodeid": self.PFX + nid, "outcome": oc}
                         for nid, oc in outcomes],
               "summary": {"collected": len(outcomes)}}
        p = tmp_path / "report.json"
        p.write_text(json.dumps(rep))
        return p

    def _fake_pytest(self, tmp_path, outcome):
        # Reads the @argfile node IDs + --json-report-file target and writes a
        # report where each re-run test gets `outcome`.
        src = (
            "import sys, json\n"
            "out=[a.split('=',1)[1] for a in sys.argv if a.startswith('--json-report-file=')][0]\n"
            "argf=[a[1:] for a in sys.argv if a.startswith('@')][0]\n"
            "ids=[l.strip() for l in open(argf) if l.strip()]\n"
            f"json.dump({{'tests':[{{'nodeid':i,'outcome':{outcome!r}}} for i in ids],"
            "'summary':{'collected':len(ids)}}, open(out,'w'))\n"
        )
        f = tmp_path / "fake_pytest.py"
        f.write_text(src)
        return f

    def _run(self, tmp_path, report, fake, extra=()):
        import subprocess
        cmd = [sys.executable, self.GATE_PY, "recover-and-gate",
               "--report", str(report), "--strip-prefix", self.PFX,
               "--prefix", self.PFX, "--settle-seconds", "0",
               "--workdir", str(tmp_path), *extra,
               "--", sys.executable, str(fake)]
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_transient_victims_recovered_pass(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed"),
                                       ("c.py::test_c", "passed")])
        fake = self._fake_pytest(tmp_path, "passed")  # the re-run passes
        r = self._run(tmp_path, report, fake)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "gate PASS" in r.stdout

    def test_persistent_failure_reds(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest(tmp_path, "failed")  # the re-run still fails
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "2"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "2 residual" in r.stdout
        assert "a.py::test_a" in r.stdout  # residual reported stripped (bare)

    def test_missing_report_fails_closed(self, tmp_path):
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, tmp_path / "does_not_exist.json", fake)
        assert r.returncode == 1

    def test_clean_run_passes_without_rerun(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "passed"),
                                       ("b.py::test_b", "xfailed")])
        fake = self._fake_pytest(tmp_path, "failed")  # must never be invoked
        r = self._run(tmp_path, report, fake)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "re-run pass 1: 0 failing" in r.stdout

    def test_over_transient_limit_left_for_gate(self, tmp_path):
        report = self._base(tmp_path, [(f"a.py::t{i}", "failed") for i in range(5)])
        fake = self._fake_pytest(tmp_path, "passed")
        # limit below the failing count -> no re-run, residual reds the gate
        r = self._run(tmp_path, report, fake, extra=["--transient-limit", "3"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "too many failures" in r.stdout

    def _fake_pytest_batch_dies(self, tmp_path, hang_marker):
        # Mimics a pytest-timeout `thread` kill: the process dies without writing
        # a report. The BATCH invocation (@argfile) always dies; an isolated
        # invocation (bare node ID) dies only for the test carrying hang_marker
        # and otherwise reports a pass.
        src = (
            "import sys, json\n"
            "out=[a.split('=',1)[1] for a in sys.argv if a.startswith('--json-report-file=')][0]\n"
            "if [a for a in sys.argv if a.startswith('@')]:\n"
            "    sys.exit(1)\n"
            "ids=[a for a in sys.argv[1:] if '::' in a and not a.startswith('-')]\n"
            f"if any({hang_marker!r} in i for i in ids):\n"
            "    sys.exit(1)\n"
            "json.dump({'tests':[{'nodeid':i,'outcome':'passed'} for i in ids],"
            "'summary':{'collected':len(ids)}}, open(out,'w'))\n"
        )
        f = tmp_path / "fake_pytest_hang.py"
        f.write_text(src)
        return f

    def test_batch_abort_falls_back_to_isolated_rerun(self, tmp_path):
        # Regression from a full-suite gate run: the batched re-run is a single
        # pytest process, so a --timeout kill on ONE hanging test takes the whole
        # batch down before json-report writes anything. Recovery used to stop there,
        # scoring every crash victim in the set as residual (21 of them, of which
        # only the hanger was real). It must now fall back to one process per
        # test: the hanger stays failed, everything else still recovers.
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("hang.py::test_hang", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "test_hang")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "1"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "falling back to one process per test" in r.stdout
        assert "isolated re-run produced 2/3 report(s)." in r.stdout
        assert "1 residual" in r.stdout
        assert "hang.py::test_hang" in r.stdout      # the real failure survives
        assert "a.py::test_a" not in r.stdout        # victim recovered, not residual
        assert "b.py::test_b" not in r.stdout

    def test_isolated_rerun_recovers_every_victim(self, tmp_path):
        # Same batch abort, but nothing actually hangs on the isolated re-run:
        # every victim recovers and the gate goes green.
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "__never_matches__")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "1"])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "isolated re-run produced 2/2 report(s)." in r.stdout

    def test_batch_and_isolated_both_dead_stops(self, tmp_path):
        # If neither the batch nor any isolated re-run produces a report, recovery
        # must stop and gate on what it has rather than loop or score green.
        report = self._base(tmp_path, [("a.py::test_a", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "test_a")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "3"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "re-run produced no report; stopping." in r.stdout
        assert "1 residual" in r.stdout

    def test_merge_staged_in_report_dir_survives_cross_device(self, tmp_path, monkeypatch):
        # Regression: the merged report must be staged in the REPORT's directory so
        # the final os.replace is intra-device. When --workdir (a runner temp dir)
        # and the report (an artifact-staging dir) are different mounts, staging the
        # merged file in workdir made os.replace raise OSError(EXDEV) and abort
        # recovery, reding the gate on transient crash-cascade victims that the
        # serial re-run had already cleared.
        import errno
        from argparse import Namespace
        import functional_gate as fg
        reportdir = tmp_path / "artifacts"; reportdir.mkdir()
        workdir = tmp_path / "agenttmp"; workdir.mkdir()
        report = reportdir / "report.json"
        report.write_text(json.dumps(
            {"tests": [{"nodeid": self.PFX + "a.py::test_a", "outcome": "failed"},
                       {"nodeid": self.PFX + "b.py::test_b", "outcome": "failed"}],
             "summary": {"collected": 2}}))
        fake = self._fake_pytest(tmp_path, "passed")  # re-run passes -> transient
        real_replace = os.replace
        def guarded_replace(src, dst, *a, **k):  # simulate a cross-mount boundary
            if os.path.dirname(os.path.abspath(src)) != os.path.dirname(os.path.abspath(dst)):
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            return real_replace(src, dst, *a, **k)
        monkeypatch.setattr(fg.os, "replace", guarded_replace)
        rc = fg.cmd_recover_and_gate(Namespace(
            report=str(report), strip_prefix=self.PFX, prefix=self.PFX,
            workdir=str(workdir), output=str(workdir / "gate-failures.txt"),
            max_passes=3, transient_limit=400, settle_seconds=0,
            rerun_cmd=["--", sys.executable, str(fake)]))
        assert rc == 0  # merged staged in report_dir -> intra-device replace -> recovered

    # ---- --expected-ids: the xdist worker-death hole (assigned tests whose
    # ---- outcomes were never recorded; a full-suite leg lost 1,175 of
    # ---- 12,094 that way and scored green) --------------------------------

    def _expected(self, tmp_path, ids, noise=True):
        lines = [self.PFX + i for i in ids]
        if noise:
            lines += ["", "3 tests collected in 0.42s"]  # manifest-style noise
        f = tmp_path / "expected_ids.txt"
        f.write_text("\n".join(lines) + "\n")
        return f

    def test_unrecorded_assigned_tests_are_recovered(self, tmp_path):
        # 3 assigned, 1 recorded: the other 2 must be re-run, merged, and PASS.
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2", "c.py::t3"])
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "0 failing, 2 unrecorded" in r.stdout
        merged = json.loads(report.read_text())
        assert len(merged["tests"]) == 3  # outcomes now recorded for all assigned

    def test_unrecorded_over_limit_reds_the_gate(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2", "c.py::t3"])
        fake = self._fake_pytest(tmp_path, "passed")  # never reached: over limit
        r = self._run(tmp_path, report, fake,
                      extra=["--expected-ids", str(exp), "--missing-limit", "1"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "too many unrecorded tests (2 > 1)" in r.stdout
        assert "b.py::t2" in r.stdout  # unrecorded tests reported as gate failures

    def test_unrecorded_test_failing_on_rerun_stays_red(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2"])
        fake = self._fake_pytest(tmp_path, "failed")  # the lost test genuinely fails
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "1 residual" in r.stdout
        assert "b.py::t2" in r.stdout

    def test_complete_report_with_expected_ids_passes_without_rerun(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed"),
                                       ("b.py::t2", "xfailed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2"])
        fake = self._fake_pytest(tmp_path, "failed")  # must never be invoked
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "0 failing, 0 unrecorded" in r.stdout

    def test_empty_expected_ids_file_fails_closed(self, tmp_path):
        # An empty assigned set means the caller's slice/manifest pipeline broke;
        # gating "nothing was expected" green would hide it.
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = tmp_path / "expected_ids.txt"
        exp.write_text("3 tests collected in 0.42s\n")  # noise only, no node IDs
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "holds no node IDs" in r.stdout


class TestVerifySplitUniverses:
    """Cross-leg guard for the stride slice used by split-collection.

    Each parallel leg collects the suite itself and then takes
    ids[split_id::num_splits]. That is a partition ONLY if every leg sliced the
    same sorted universe; a leg whose collection silently omits one node shifts
    every later position, so it runs the next leg's tests while its own share
    runs nowhere -- and every leg still passes. These tests pin that the skew
    fails instead of scoring green.
    """

    def _u(self, tmp_path, tag, mode, uhash, count):
        d = tmp_path / f"art-{tag}"
        d.mkdir(parents=True, exist_ok=True)
        p = d / "universe.txt"
        p.write_text(f"{tag} {mode} {uhash} {count}\n", encoding="utf-8")
        return str(p)

    def test_identical_universes_pass(self, tmp_path):
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "abc123", 48374)
                 for i in range(4)]
        files.append(self._u(tmp_path, "np", "noparallel", "deadbeef", 1913))
        assert fg.verify_split_universes(files, 4) == []

    def test_one_skewed_leg_is_rejected(self, tmp_path):
        # THE production failure: p2's collect dropped a node, so its hash and
        # count differ and its stride is shifted against the others'.
        import functional_gate as fg
        files = [self._u(tmp_path, "p0", "parallel", "abc123", 48374),
                 self._u(tmp_path, "p1", "parallel", "abc123", 48374),
                 self._u(tmp_path, "p2", "parallel", "9999ff", 48373),
                 self._u(tmp_path, "p3", "parallel", "abc123", 48374)]
        problems = fg.verify_split_universes(files, 4)
        assert problems, "skewed universes must not pass"
        assert any("DIFFERENT universes" in p for p in problems)
        assert any("p2=9999ff" in p for p in problems)

    def test_noparallel_hash_may_differ(self, tmp_path):
        # The serial leg collects a different marker set by design.
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "same", 10) for i in range(2)]
        files.append(self._u(tmp_path, "np", "noparallel", "totally-different", 3))
        assert fg.verify_split_universes(files, 2) == []

    def test_missing_leg_is_rejected(self, tmp_path):
        # A leg that never reported leaves its stride unrun; no per-leg gate sees it.
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "same", 10) for i in range(3)]
        problems = fg.verify_split_universes(files, 4)
        assert any("expected 4 parallel split(s)" in p for p in problems)

    def test_repeated_record_does_not_inflate_the_split_count(self, tmp_path):
        # A repeated record is one leg reporting twice (stage retry), so it must
        # NOT be counted as an extra split and let a missing leg slip through:
        # two real legs plus a repeat of p0 is still two splits, not three.
        import functional_gate as fg
        files = [self._u(tmp_path, "p0", "parallel", "same", 10),
                 self._u(tmp_path, "p1", "parallel", "same", 10)]
        d = tmp_path / "dup"; d.mkdir()
        p = d / "universe.txt"; p.write_text("p0 parallel same 10\n", encoding="utf-8")
        files.append(str(p))
        problems = fg.verify_split_universes(files, 3)
        assert any("expected 3 parallel split(s)" in p for p in problems)
        assert any("got 2" in p for p in problems)

    def test_stage_retry_republishing_every_leg_is_not_a_duplicate(self, tmp_path):
        # Artifact names carry System.PhaseAttempt, so a stage RETRY leaves the
        # attempt-1 records in place and adds attempt-2 ones. The verify job then
        # downloads one record per leg PER ATTEMPT. That must not be mistaken for
        # two legs claiming the same split id.
        import functional_gate as fg
        files = []
        for attempt in (1, 2):
            for i in range(4):
                d = tmp_path / f"art-p{i}-{attempt}"
                d.mkdir(parents=True)
                p = d / "universe.txt"
                p.write_text(f"p{i} parallel abc123 48374\n", encoding="utf-8")
                files.append(str(p))
        assert len(files) == 8
        assert fg.verify_split_universes(files, 4) == []

    def test_same_tag_reporting_two_universes_is_rejected(self, tmp_path):
        # Dedupe must not hide a leg that genuinely disagreed with itself.
        import functional_gate as fg
        d1 = tmp_path / "a1"; d1.mkdir()
        (d1 / "universe.txt").write_text("p0 parallel aaa 10\n", encoding="utf-8")
        d2 = tmp_path / "a2"; d2.mkdir()
        (d2 / "universe.txt").write_text("p0 parallel bbb 9\n", encoding="utf-8")
        problems = fg.verify_split_universes([str(d1 / "universe.txt"),
                                              str(d2 / "universe.txt")], 1)
        assert any("CONFLICTING universes" in p for p in problems)

    def test_malformed_record_is_rejected(self, tmp_path):
        import functional_gate as fg
        d = tmp_path / "bad"; d.mkdir()
        p = d / "universe.txt"; p.write_text("garbage\n", encoding="utf-8")
        problems = fg.verify_split_universes([str(p)], 1)
        assert any("unreadable universe record" in p for p in problems)

    def test_cmd_exits_nonzero_on_skew(self, tmp_path):
        from argparse import Namespace
        import functional_gate as fg
        self._u(tmp_path, "p0", "parallel", "aaa", 10)
        self._u(tmp_path, "p1", "parallel", "bbb", 10)
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=2))
        assert rc == 1

    def test_cmd_fails_closed_when_no_records_found(self, tmp_path):
        # An empty download must never be read as "nothing disagreed".
        from argparse import Namespace
        import functional_gate as fg
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=4))
        assert rc == 1

    def test_cmd_passes_on_agreement(self, tmp_path):
        from argparse import Namespace
        import functional_gate as fg
        for i in range(4):
            self._u(tmp_path, f"p{i}", "parallel", "same", 48374)
        self._u(tmp_path, "np", "noparallel", "other", 1913)
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=4))
        assert rc == 0


class TestVerifySplitUniversesArtifactLayout:
    """Pins the REAL downloaded layout, which the first cut of these tests missed.

    A gate run failed with "no universe.txt found" even though all five
    legs wrote one. Cause: the artifact download matches its patterns against
    each file's path INSIDE its artifact, not against '<artifactName>/<path>',
    so an artifact-name-qualified pattern filtered 0 files from all 107
    artifacts. The unit tests could not have caught it -- they built a flat
    directory of records rather than the <workspace>/<artifactName>/universe.txt
    tree the download actually produces. These tests use that tree.
    """
    PFX = "functional-test-results"

    def _leg(self, ws, tag, uhash, count, mode="parallel", attempt=1, prefix=None):
        d = ws / f"{prefix or self.PFX}-{tag}-{attempt}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "universe.txt").write_text(
            f"{tag} {mode} {uhash} {count}\n", encoding="utf-8")
        # the artifact also carries the rest of the leg's results
        (d / "results.xml").write_text("<testsuite/>", encoding="utf-8")
        return d

    def _ns(self, ws, expected, prefix=""):
        from argparse import Namespace
        return Namespace(dir=[str(ws)], universe=[], expected_splits=expected,
                         artifact_prefix=prefix)

    def test_real_download_layout_passes(self, tmp_path):
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        self._leg(tmp_path, "np", "4133a3a9c9142a79", 1913, mode="noparallel")
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_real_download_layout_catches_skew(self, tmp_path):
        import functional_gate as fg
        for i in (0, 1, 3):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        self._leg(tmp_path, "p2", "deadbeefdeadbeef", 48373)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 1

    def test_records_from_another_stage_are_ignored(self, tmp_path):
        # A second instance of this stage template (e.g. a standalone-gateway
        # variant) publishes its own legs into the same run. Those must not be
        # counted here, or the split count and duplicate checks fire for no real
        # reason.
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "ffff0000ffff0000", 12345,
                      prefix="standalone-gw-test-results")
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_stage_retry_layout_passes(self, tmp_path):
        # attempt 1 and attempt 2 artifacts both present after a stage retry
        import functional_gate as fg
        for attempt in (1, 2):
            for i in range(4):
                self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374,
                          attempt=attempt)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_empty_workspace_fails_closed(self, tmp_path):
        import functional_gate as fg
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 1

    def test_prefix_filtering_everything_out_fails_closed(self, tmp_path):
        # The same shape: records exist, but none are accepted. Must fail,
        # and must not be mistaken for "nothing disagreed".
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        rc = fg.cmd_verify_split_universes(
            self._ns(tmp_path, 4, "some-other-artifact-prefix"))
        assert rc == 1

    def test_no_prefix_accepts_everything(self, tmp_path):
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, "")) == 0
