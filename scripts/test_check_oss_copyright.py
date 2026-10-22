#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Regression coverage for OSS copyright checking and conservative fixes."""

from __future__ import annotations

import ast
import contextlib
import errno
import io
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import check_oss_copyright as checker
from check_oss_copyright import COPYRIGHT, LICENSE, normalize


SCRIPT = Path(__file__).resolve().with_name("check_oss_copyright.py")


class HeaderTests(unittest.TestCase):
    def fix(self, suffix: str, source: bytes, add_missing: bool = False) -> bytes:
        result, _ = normalize(Path("example" + suffix), source, add_missing)
        self.assertEqual(normalize(Path("example" + suffix), result)[0], result)
        return result

    def test_c_banner_and_description_are_preserved(self) -> None:
        source = (
            "/*-------------------------------------------------------------------------\n"
            f" * {COPYRIGHT}  All rights reserved.\n"
            " * SPDX-License-Identifier: MIT\n *\n * src/example.c\n"
            " * Description.\n *-------------------------------------------------------------------------\n */\n"
            "int example;\n"
        )
        expected = source.replace(
            f"{COPYRIGHT}  All rights reserved.\n * SPDX-License-Identifier: MIT",
            f"{COPYRIGHT}\n * {LICENSE}",
        )
        for suffix in (".c", ".h"):
            self.assertEqual(self.fix(suffix, source.encode()), expected.encode())

    def test_rust_block_becomes_line_comments(self) -> None:
        source = (
            f"/*---\n * {COPYRIGHT}  All rights reserved.\n"
            " *\n * src/example.rs\n *---\n */\n#![forbid(unsafe_code)]\n"
        )
        expected = (
            f"// {COPYRIGHT}\n// {LICENSE}.\n//\n// src/example.rs\n"
            "#![forbid(unsafe_code)]\n"
        )
        self.assertEqual(self.fix(".rs", source.encode()), expected.encode())

    def test_sql_block_and_inline_include(self) -> None:
        source = f"/* {COPYRIGHT} SPDX-License-Identifier: MIT */ \\i sql/base.sql"
        expected = f"-- {COPYRIGHT}\n-- {LICENSE}.\n \\i sql/base.sql"
        self.assertEqual(self.fix(".sql", source.encode()), expected.encode())

    def test_sql_removes_spdx_and_preserves_statements(self) -> None:
        source = (
            f"-- {COPYRIGHT}\n-- {LICENSE}.\n-- SPDX-License-Identifier: MIT\n\n"
            "SELECT 'Copyright (c) Another Author. SPDX-License-Identifier: MIT';\n"
        ).encode()
        self.assertEqual(
            self.fix(".sql", source),
            source.replace(b"-- SPDX-License-Identifier: MIT\n", b""),
        )

    def test_add_missing_requires_explicit_confirmation(self) -> None:
        with self.assertRaisesRegex(ValueError, "confirm authorship"):
            normalize(Path("example.sql"), b"SELECT 1;")
        for suffix, marker in ((".rs", "//"), (".sql", "--"), (".sh", "#")):
            with self.subTest(suffix=suffix):
                expected = f"{marker} {COPYRIGHT}\n{marker} {LICENSE}.\n\nbody"
                self.assertEqual(self.fix(suffix, b"body", True), expected.encode())

    def test_shebang_and_executable_body_are_preserved(self) -> None:
        for suffix in (".sh", ".bash", ""):
            source = b"#!/bin/sh\nset -eu\nprintf '%s\\n' ok\n"
            result = self.fix(suffix, source, True)
            self.assertTrue(result.startswith(b"#!/bin/sh\n# Copyright"))
            self.assertTrue(result.endswith(source.split(b"\n", 1)[1]))

    def test_shebang_without_final_newline(self) -> None:
        self.assertTrue(
            self.fix(".sh", b"#!/bin/sh", True).startswith(b"#!/bin/sh\n# Copyright")
        )

    def test_existing_copyright_in_source_is_not_a_header(self) -> None:
        source = f"SELECT '{COPYRIGHT}';".encode()
        with self.assertRaisesRegex(ValueError, "missing copyright"):
            normalize(Path("example.sql"), source)
        self.assertTrue(self.fix(".sql", source, True).endswith(source))

    def test_third_party_only_is_never_relabelled(self) -> None:
        source = (
            b"/*\n * Copyright 2025 Example Contributors\n"
            b" * SPDX-License-Identifier: Apache-2.0\n */\nint example;\n"
        )
        result, third_party = normalize(Path("example.c"), source, True)
        self.assertEqual(result, source)
        self.assertTrue(third_party)

    def test_third_party_notice_without_symbol_or_year_is_preserved(self) -> None:
        source = b"/* Copyright Example Contributors */\nint example;\n"
        result, third_party = normalize(Path("example.c"), source, True)
        self.assertEqual(result, source)
        self.assertTrue(third_party)

    def test_compact_c_notice_uses_the_c_block_style(self) -> None:
        source = f"/* {COPYRIGHT} */\nint example;\n".encode()
        expected = f"/*\n * {COPYRIGHT}\n * {LICENSE}\n */\nint example;\n".encode()
        self.assertEqual(self.fix(".c", source), expected)

    def test_mixed_ownership_retains_portions_and_license_terms(self) -> None:
        source = (
            f"/*\n * Portions {COPYRIGHT}  All rights reserved.\n"
            " * Portions Copyright (c) 2020 Example Contributors\n"
            " * Permission to use, copy, modify, and distribute this software.\n */\n"
        ).encode()
        result = self.fix(".h", source)
        self.assertIn(f" * Portions {COPYRIGHT}\n * {LICENSE}\n".encode(), result)
        self.assertTrue(result.endswith(source.split(b"\n", 2)[2]))

    def test_notice_after_long_description(self) -> None:
        source = (
            "/*\n"
            + " * Description.\n" * 100
            + f" * {COPYRIGHT}  All rights reserved.\n */\nint example;\n"
        ).encode()
        self.assertIn(LICENSE.encode(), self.fix(".c", source))

    def test_malformed_or_conflicting_notice_requires_review(self) -> None:
        for notice in (
            f"/* {COPYRIGHT} SPDX-License-Identifier: Apache-2.0 */",
            "/* Copyright (c) 2025 Microsoft Corporation. */",
            "/* unterminated",
        ):
            with self.subTest(notice=notice):
                with self.assertRaises(ValueError):
                    normalize(Path("example.c"), notice.encode(), True)

    def test_bom_crlf_and_missing_final_newline_are_preserved(self) -> None:
        source = b"\xef\xbb\xbf#!/bin/sh\r\nprintf ok"
        result = self.fix(".sh", source, True)
        self.assertTrue(result.startswith(b"\xef\xbb\xbf#!/bin/sh\r\n"))
        self.assertTrue(result.endswith(b"printf ok"))
        self.assertNotIn(b"\n", result.replace(b"\r\n", b""))

    def test_mixed_line_endings_are_reported(self) -> None:
        with self.assertRaisesRegex(ValueError, "mixed line endings"):
            normalize(Path("example.sql"), b"SELECT 1;\r\nSELECT 2;\n", True)

    def test_nested_rust_comment_is_not_partially_rewritten(self) -> None:
        source = f"/* {COPYRIGHT}\n/* details */\n*/\nfn example() {{}}\n".encode()
        with self.assertRaisesRegex(ValueError, "nested leading block"):
            normalize(Path("example.rs"), source, True)

    def test_empty_file(self) -> None:
        expected = f"/*\n * {COPYRIGHT}\n * {LICENSE}\n */\n"
        self.assertEqual(self.fix(".c", b"", True), expected.encode())

    def test_header_only_file_has_no_blank_lines_at_eof(self) -> None:
        source = f"-- {COPYRIGHT}\n-- {LICENSE}.\n\n".encode()
        self.assertEqual(self.fix(".sql", source), source.rstrip() + b"\n")

    def test_python_docstring_and_future_import_remain_unchanged(self) -> None:
        source = b'"""Module documentation."""\nfrom __future__ import annotations\nvalue = 1\n'
        result = self.fix(".py", source, True)
        self.assertTrue(result.startswith(f"# {COPYRIGHT}\n# {LICENSE}.\n".encode()))
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(result)))

    def test_python_shebang_and_encoding_cookie_stay_at_the_front(self) -> None:
        source = (
            b'#!/usr/bin/env python3\n# coding: latin-1\n"""caf\xe9"""\nvalue = 1\n'
        )
        result = self.fix(".py", source, True)
        self.assertTrue(result.startswith(source.split(b'"""', 1)[0]))
        self.assertTrue(result.endswith(b'"""caf\xe9"""\nvalue = 1\n'))
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(result)))

    def test_python_cookie_is_preserved_when_it_follows_a_copyright_line(self) -> None:
        source = (
            f"# {COPYRIGHT} All rights reserved.\n# coding: utf-8\n"
            '"""Module documentation."""\n'
        ).encode()
        result = self.fix(".py", source)
        self.assertTrue(
            result.startswith(
                f"# coding: utf-8\n# {COPYRIGHT}\n# {LICENSE}.\n".encode()
            )
        )
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(result)))

    def test_python_bom_crlf_and_cookie_are_preserved(self) -> None:
        source = b"\xef\xbb\xbf#!/usr/bin/python3\r\n# coding: utf-8\r\nvalue = 1"
        result = self.fix(".py", source, True)
        self.assertTrue(
            result.startswith(b"\xef\xbb\xbf#!/usr/bin/python3\r\n# coding: utf-8\r\n")
        )
        self.assertNotIn(b"\n", result.replace(b"\r\n", b""))
        self.assertTrue(result.endswith(b"value = 1"))

    def test_python_third_party_docstring_is_not_relabelled(self) -> None:
        source = b'"""Copyright Example Contributors.\nLicensed under the MIT License.\n"""\n'
        result, third_party = normalize(Path("example.py"), source, True)
        self.assertEqual(result, source)
        self.assertTrue(third_party)

    def test_python_third_party_header_and_cookie_are_not_reordered(self) -> None:
        source = (
            b"# Copyright Example Contributors.\n# coding: latin-1\nvalue = 'caf\xe9'\n"
        )
        result, third_party = normalize(Path("example.py"), source, True)
        self.assertEqual(result, source)
        self.assertTrue(third_party)

    def test_python_microsoft_docstring_is_preserved(self) -> None:
        source = f'"""{COPYRIGHT}\nModule documentation.\n"""\n'.encode()
        result = self.fix(".py", source)
        self.assertTrue(result.startswith(f"# {COPYRIGHT}\n# {LICENSE}.\n".encode()))
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(result)))

    def test_makefile_recipes_and_variables_are_preserved(self) -> None:
        source = b"VALUE := hello\nall:\n\t@echo $(VALUE)\n"
        for name in (
            "Makefile",
            "Makefile.global",
            "GNUmakefile",
            "makefile",
            "rules.mk",
        ):
            with self.subTest(name=name):
                result, _ = normalize(Path(name), source, True)
                self.assertEqual(
                    result, f"# {COPYRIGHT}\n# {LICENSE}.\n\n".encode() + source
                )
                self.assertEqual(normalize(Path(name), result)[0], result)

    def test_cargo_makefile_uses_hash_comments(self) -> None:
        source = b'[tasks.build]\ncommand = "cargo"\nargs = ["build"]\n'
        result, _ = normalize(Path("Makefile.toml"), source, True)
        self.assertEqual(result, f"# {COPYRIGHT}\n# {LICENSE}.\n\n".encode() + source)
        self.assertEqual(normalize(Path("Makefile.toml"), result)[0], result)

    def test_encoding_text_inside_python_strings_is_not_a_cookie(self) -> None:
        for source in (
            '"""Module documentation\n# coding: utf-8\nretained text\n"""\nvalue = 1\n',
            'value = """String data\n# coding: latin-1\nretained text\n"""\n',
        ):
            with self.subTest(source=source):
                result = self.fix(".py", source.encode(), True)
                self.assertEqual(
                    ast.dump(ast.parse(source)), ast.dump(ast.parse(result))
                )
                self.assertTrue(result.endswith(source.encode()))

    def test_non_mit_expressions_are_refused_in_every_header_position(self) -> None:
        for declaration in (
            "MIT OR Apache-2.0",
            "MIT AND BSD-3-Clause",
            "MIT-0",
            "Apache-2.0",
        ):
            for source in (
                f"// {COPYRIGHT}\n// SPDX-License-Identifier: {declaration}\nfn main() {{}}\n",
                f"/* {COPYRIGHT} */\n/* SPDX-License-Identifier: {declaration} */\nfn main() {{}}\n",
                f"// SPDX-License-Identifier: {declaration}\nfn main() {{}}\n",
            ):
                with self.subTest(declaration=declaration, source=source):
                    with self.assertRaisesRegex(ValueError, "license|SPDX"):
                        normalize(Path("example.rs"), source.encode(), True)

    def test_non_mit_license_sentence_is_not_relabelled(self) -> None:
        source = f"// {COPYRIGHT}\n// Licensed under the Apache License, Version 2.0.\nfn main() {{}}\n"
        with self.assertRaisesRegex(ValueError, "license|License"):
            normalize(Path("example.rs"), source.encode())

    def test_mixed_owner_license_notices_are_preserved(self) -> None:
        foreign_notice = (
            " * Copyright Example Contributors\n"
            " * Licensed under the MIT License.\n"
            " * SPDX-License-Identifier: MIT\n"
        )
        source = f"/*\n * {COPYRIGHT} All rights reserved.\n{foreign_notice} */\nint value;\n"
        result = self.fix(".c", source.encode())
        self.assertIn(foreign_notice.encode(), result)
        self.assertIn(f" * {COPYRIGHT}\n * {LICENSE}\n".encode(), result)

    def test_rust_documentation_is_not_rewritten(self) -> None:
        for documentation in (
            f"/*! {COPYRIGHT}\nModule documentation.\n*/\n",
            f"/**\n * {COPYRIGHT}\n * Item documentation.\n */\n",
            f"//! {COPYRIGHT}\n//! Module documentation.\n",
            f"/// {COPYRIGHT}\n/// Item documentation.\n",
        ):
            with self.subTest(documentation=documentation):
                source = (documentation + "pub fn example() {}\n").encode()
                result = self.fix(".rs", source)
                self.assertTrue(
                    result.startswith(f"// {COPYRIGHT}\n// {LICENSE}.\n".encode())
                )
                self.assertTrue(result.endswith(source))

    def test_adjacent_rust_documentation_stays_documentation(self) -> None:
        for documentation in (
            "//! Module documentation.\n",
            "/// Item documentation.\n",
        ):
            source = f"// {COPYRIGHT} All rights reserved.\n{documentation}pub fn example() {{}}\n"
            result = self.fix(".rs", source.encode())
            self.assertTrue(
                result.endswith((documentation + "pub fn example() {}\n").encode())
            )

    def test_third_party_rust_documentation_is_not_relabelled(self) -> None:
        for documentation in (
            "/*! Copyright Example Contributors\nDocumentation.\n*/\n",
            "/// Copyright Example Contributors\n/// Documentation.\n",
        ):
            source = (documentation + "pub fn example() {}\n").encode()
            result, third_party = normalize(Path("example.rs"), source, True)
            self.assertEqual(result, source)
            self.assertTrue(third_party)

    def test_rust_and_makefile_shebangs_remain_first(self) -> None:
        for filename, source in (
            ("example.rs", b"#!/usr/bin/env rust-script\nfn main() {}\n"),
            ("Makefile", b"#!/usr/bin/make -f\nall:\n\t@echo ok\n"),
        ):
            with self.subTest(filename=filename):
                result, _ = normalize(Path(filename), source, True)
                self.assertTrue(result.startswith(source.split(b"\n", 1)[0] + b"\n"))
                self.assertEqual(normalize(Path(filename), result)[0], result)
                self.assertTrue(result.endswith(source.split(b"\n", 1)[1]))

    def test_case_variant_microsoft_owner_is_not_a_third_party_exemption(self) -> None:
        source = b"/*\n * COPYRIGHT (c) MICROSOFT CORPORATION.\n */\nint value;\n"
        with self.assertRaisesRegex(ValueError, "Microsoft notice"):
            normalize(Path("example.c"), source)

    def test_microsoft_mention_does_not_reassign_a_foreign_notice(self) -> None:
        source = b"/*\n * Copyright Example Contributors\n * Interoperates with Microsoft Corporation software.\n */\n"
        result, foreign = normalize(Path("example.c"), source, True)
        self.assertEqual(result, source)
        self.assertTrue(foreign)

    def test_python_concatenated_third_party_docstrings_are_preserved(self) -> None:
        for source in (
            b'"""Copyright Example """ """Contributors."""\nvalue = 1\n',
            b'("""Copyright Example Contributors."""\n """Documentation.""")\nvalue = 1\n',
        ):
            with self.subTest(source=source):
                result, third_party = normalize(Path("example.py"), source, True)
                self.assertEqual(result, source)
                self.assertTrue(third_party)

    def test_python_docstring_followed_by_semicolon_keeps_program_behavior(
        self,
    ) -> None:
        source = b'"""Module documentation."""; value = 1\n'
        result = self.fix(".py", source, True)
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(result)))

    def test_only_physical_newlines_split_comment_lines(self) -> None:
        source = f"# {COPYRIGHT}\n# Documentation\u2028Copyright Example Contributors\nvalue = 1\n".encode()
        result = self.fix(".py", source)
        self.assertIn(
            b"# Documentation\xe2\x80\xa8Copyright Example Contributors\n", result
        )

    def test_bare_carriage_returns_are_refused_without_rewriting(self) -> None:
        with self.assertRaisesRegex(ValueError, "line endings"):
            normalize(Path("example.sh"), b"#!/bin/sh\rexit 0\r", True)


class CommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "--quiet")

    def git(self, *args: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", "-C", str(self.root), *args],
            check=True,
            capture_output=True,
        )

    def track(self, name: str, content: bytes) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        self.git("add", "--", name)
        return path

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True,
            text=True,
            check=False,
            cwd=self.directory.name,
        )

    def run_in_process(self, *args: str) -> subprocess.CompletedProcess[str]:
        arguments = ["--root", str(self.root), *args]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                result = checker.main(arguments)
        return subprocess.CompletedProcess(
            arguments, result, output.getvalue(), errors.getvalue()
        )

    def test_check_fails_without_writing_then_fix_is_idempotent(self) -> None:
        path = self.track("oss/space here/example.sql", b"SELECT 1;")
        original = path.read_bytes()
        self.assertEqual(self.run_cli().returncode, 1)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(self.run_cli("--fix").returncode, 1)
        self.assertEqual(path.read_bytes(), original)
        fixed = self.run_cli("--fix", "--add-missing")
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        check = self.run_cli("--check")
        self.assertEqual(check.returncode, 0, check.stderr)
        again = self.run_cli("--fix")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("updated 0", again.stdout)

    def test_scope_and_shell_permissions(self) -> None:
        shell = self.track("oss/scripts/postinst", b"#!/bin/sh\nexit 0\n")
        shell.chmod(0o755)
        self.git("add", "--", "oss/scripts/postinst")
        excluded = [
            self.track("outside.c", b"int untouched;"),
            self.track("oss/LICENSE", b"license notice"),
            self.track("oss/expected/result.out", b"SELECT 1;"),
        ]
        untracked = self.root / "oss/untracked.c"
        untracked.write_bytes(b"int untouched;")
        excluded.append(untracked)
        originals = {path: path.read_bytes() for path in excluded}
        result = self.run_cli(
            "--root", str(self.root / "oss"), "--fix", "--add-missing"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(shell.stat().st_mode & 0o777, 0o755)
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)

    def test_standalone_checkout_uses_default_source_root(self) -> None:
        copied_script = self.track(
            "scripts/check_oss_copyright.py", SCRIPT.read_bytes()
        )
        source = self.track("module/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as elsewhere:
            result = subprocess.run(
                [sys.executable, str(copied_script), "--fix", "--add-missing"],
                cwd=elsewhere,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(COPYRIGHT.encode(), source.read_bytes())

    def test_subdirectory_checkout_does_not_scan_siblings(self) -> None:
        copied_script = self.track(
            "project/scripts/check_oss_copyright.py", SCRIPT.read_bytes()
        )
        source = self.track("project/module/example.c", b"int example;\n")
        sibling = self.track("sibling/example.c", b"int untouched;\n")
        with tempfile.TemporaryDirectory() as elsewhere:
            result = subprocess.run(
                [sys.executable, str(copied_script), "--fix", "--add-missing"],
                cwd=elsewhere,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 2 files", result.stdout)
        self.assertIn(COPYRIGHT.encode(), source.read_bytes())
        self.assertEqual(sibling.read_bytes(), b"int untouched;\n")

    def test_worktree_symlink_is_not_followed(self) -> None:
        path = self.track("oss/example.c", b"int example;")
        target = self.root / "target.c"
        target.write_bytes(b"int untouched;")
        path.unlink()
        path.symlink_to(target)
        result = self.run_cli("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(target.read_bytes(), b"int untouched;")

    def test_hardlinked_source_does_not_modify_an_external_inode(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / "example.c"
            original = b"int untouched;\n"
            external.write_bytes(original)
            path.unlink()
            os.link(external, path)
            result = self.run_cli("--fix", "--add-missing")
            self.assertEqual(external.read_bytes(), original)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(COPYRIGHT.encode(), path.read_bytes())
            self.assertNotEqual(path.stat().st_ino, external.stat().st_ino)

    def test_symlinked_parent_cannot_overwrite_outside_repository(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        path.unlink()
        path.parent.rmdir()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)
            path.parent.symlink_to(directory, target_is_directory=True)

            result = self.run_cli("--fix", "--add-missing")

            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(result.returncode, 1)
            self.assertIn("symlink", result.stderr)

    def test_symlinked_ancestor_cannot_overwrite_outside_repository(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        path.unlink()
        path.parent.rmdir()
        (self.root / "oss").rmdir()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "module/example.c"
            target.parent.mkdir()
            original = b"int untouched;\n"
            target.write_bytes(original)
            (self.root / "oss").symlink_to(directory, target_is_directory=True)

            result = self.run_cli("--fix", "--add-missing")

            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(result.returncode, 1)
            self.assertIn("symlink", result.stderr)

    def test_symlinked_parent_within_repository_is_rejected(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        target = self.root / "other/example.c"
        target.parent.mkdir()
        original = b"int untouched;\n"
        target.write_bytes(original)
        path.unlink()
        path.parent.rmdir()
        path.parent.symlink_to(target.parent, target_is_directory=True)

        for options in ((), ("--fix", "--add-missing")):
            with self.subTest(options=options):
                result = self.run_cli(*options)
                self.assertEqual(result.returncode, 1)
                self.assertIn("symlink", result.stderr)
                self.assertEqual(target.read_bytes(), original)

    def test_symlinked_parent_is_rejected_before_shebang_discovery(self) -> None:
        path = self.track("oss/module/tool", b"#!/bin/sh\nexit 0\n")
        path.unlink()
        path.parent.rmdir()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"#!/bin/sh\nexit 0\n")
            path.parent.symlink_to(directory, target_is_directory=True)
            with mock.patch.object(
                checker, "read_source", side_effect=AssertionError("unexpected read")
            ):
                with self.assertRaisesRegex(ValueError, "symlink"):
                    checker.source_files(self.root)

    def test_dangling_parent_symlink_is_not_treated_as_a_deletion(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        path.unlink()
        path.parent.rmdir()
        path.parent.symlink_to(self.root / "missing", target_is_directory=True)
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("symlink", result.stderr)

    def test_repository_root_alias_is_supported(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            alias = Path(directory) / "checkout"
            alias.symlink_to(self.root, target_is_directory=True)
            result = self.run_cli("--root", str(alias), "--fix", "--add-missing")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(COPYRIGHT.encode(), path.read_bytes())

    def test_deleted_tracked_file_is_still_skipped(self) -> None:
        deleted = self.track("oss/deleted.c", b"int deleted;\n")
        deleted.unlink()
        self.track("oss/present.c", b"int present;\n")
        result = self.run_cli("--fix", "--add-missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 1 files", result.stdout)
        self.assertFalse(deleted.exists())

    def test_nonregular_worktree_file_is_rejected(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        path.unlink()
        path.mkdir()
        result = self.run_cli("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected a regular file", result.stderr)

    def test_parent_path_is_rechecked_before_reading(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        path.unlink()
        path.parent.rmdir()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            target.write_bytes(b"int untouched;\n")
            path.parent.symlink_to(directory, target_is_directory=True)
            with mock.patch.object(
                checker, "source_files", return_value=[Path("oss/module/example.c")]
            ):
                with mock.patch.object(
                    checker,
                    "read_source",
                    side_effect=AssertionError("unexpected read"),
                ):
                    with contextlib.redirect_stderr(io.StringIO()) as errors:
                        with contextlib.redirect_stdout(io.StringIO()):
                            result = checker.main(
                                ["--root", str(self.root), "--fix", "--add-missing"]
                            )
            self.assertEqual(result, 1)
            self.assertIn("symlink", errors.getvalue())
            self.assertEqual(target.read_bytes(), b"int untouched;\n")

    def test_parent_path_is_rechecked_before_writing(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)

            def replace_parent(
                source: Path, data: bytes, add_missing: bool
            ) -> tuple[bytes, bool]:
                updated = normalize(source, data, add_missing)
                path.unlink()
                path.parent.rmdir()
                path.parent.symlink_to(directory, target_is_directory=True)
                return updated

            with mock.patch.object(checker, "normalize", side_effect=replace_parent):
                with contextlib.redirect_stderr(io.StringIO()) as errors:
                    with contextlib.redirect_stdout(io.StringIO()):
                        result = checker.main(
                            ["--root", str(self.root), "--fix", "--add-missing"]
                        )
            self.assertEqual(result, 1)
            self.assertIn("symlink", errors.getvalue())
            self.assertEqual(target.read_bytes(), original)

    def test_parent_swap_at_replace_cannot_redirect_the_write(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)
            exchange = checker.exchange_paths
            raced: list[bool] = []

            def swap_parent(
                first_fd: int, first: str, second_fd: int, second: str
            ) -> None:
                if not raced:
                    raced.append(True)
                    path.parent.rename(self.root / "parked")
                    path.parent.symlink_to(directory, target_is_directory=True)
                exchange(first_fd, first, second_fd, second)

            with mock.patch.object(checker, "exchange_paths", side_effect=swap_parent):
                result = self.run_in_process("--fix", "--add-missing")
            self.assertTrue(raced)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("symlink", result.stderr)
            self.assertEqual(target.read_bytes(), original)

    def test_leaf_swap_at_replace_does_not_follow_the_link(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)
            exchange = checker.exchange_paths
            raced: list[bool] = []

            def swap_leaf(
                first_fd: int, first: str, second_fd: int, second: str
            ) -> None:
                if not raced:
                    raced.append(True)
                    path.unlink()
                    path.symlink_to(target)
                exchange(first_fd, first, second_fd, second)

            with mock.patch.object(checker, "exchange_paths", side_effect=swap_leaf):
                result = self.run_in_process("--fix", "--add-missing")
            self.assertTrue(raced)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(target.read_bytes(), original)
            self.assertTrue(path.is_symlink())
            self.assertIn("recovery files retained", result.stderr)

    def test_atomic_editor_save_at_publication_is_restored(self) -> None:
        path = self.track("oss/example.c", b"int initial;\n")
        edited = b"int newer_editor_save;\n"
        exchange = checker.exchange_paths
        calls: list[bool] = []

        def save_at_exchange(
            first_fd: int, first: str, second_fd: int, second: str
        ) -> None:
            if not calls:
                editor = path.parent / "editor-save"
                editor.write_bytes(edited)
                os.replace(editor, path)
            calls.append(True)
            exchange(first_fd, first, second_fd, second)

        with mock.patch.object(checker, "exchange_paths", side_effect=save_at_exchange):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(len(calls), 2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("rolled back", result.stderr)
        self.assertIn("recovery files retained", result.stderr)
        self.assertEqual(path.read_bytes(), edited)
        self.assertNotIn("Updated oss/example.c", result.stdout)

    def test_save_during_rollback_is_retained_for_recovery(self) -> None:
        path = self.track("oss/example.c", b"int initial;\n")
        first_save = b"int first_editor_save;\n"
        second_save = b"int second_editor_save;\n"
        exchange = checker.exchange_paths
        calls: list[bool] = []

        def save_at_each_exchange(
            first_fd: int, first: str, second_fd: int, second: str
        ) -> None:
            editor = path.parent / "editor-save"
            editor.write_bytes(second_save if calls else first_save)
            os.replace(editor, path)
            calls.append(True)
            exchange(first_fd, first, second_fd, second)

        with mock.patch.object(
            checker, "exchange_paths", side_effect=save_at_each_exchange
        ):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(path.read_bytes(), first_save)
        recovery = list(path.parent.glob(".copyright-*/payload"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].read_bytes(), second_save)
        self.assertIn(str(recovery[0].parent), result.stderr)

    def test_failed_rollback_retains_the_displaced_editor_save(self) -> None:
        path = self.track("oss/example.c", b"int initial;\n")
        edited = b"int newer_editor_save;\n"
        exchange = checker.exchange_paths
        calls: list[bool] = []

        def fail_rollback(
            first_fd: int, first: str, second_fd: int, second: str
        ) -> None:
            if calls:
                raise OSError(errno.EIO, "simulated rollback failure")
            editor = path.parent / "editor-save"
            editor.write_bytes(edited)
            os.replace(editor, path)
            calls.append(True)
            exchange(first_fd, first, second_fd, second)

        with mock.patch.object(checker, "exchange_paths", side_effect=fail_rollback):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("rollback failed", result.stderr)
        recovery = list(path.parent.glob(".copyright-*/payload"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].read_bytes(), edited)
        self.assertIn(str(recovery[0].parent), result.stderr)

    def test_candidate_replacement_and_content_changes_restore_original(self) -> None:
        for replace_inode in (False, True):
            with self.subTest(replace_inode=replace_inode):
                path = self.track("oss/example.c", b"int original;\n")
                original = path.read_bytes()
                substituted = b"int substituted_payload;\n"
                exchange = checker.exchange_paths
                calls: list[bool] = []

                def change_candidate(
                    first_fd: int, first: str, second_fd: int, second: str
                ) -> None:
                    if not calls:
                        if replace_inode:
                            os.unlink(first, dir_fd=first_fd)
                        fd = os.open(
                            first,
                            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                            0o600,
                            dir_fd=first_fd,
                        )
                        try:
                            os.write(fd, substituted)
                        finally:
                            os.close(fd)
                    calls.append(True)
                    exchange(first_fd, first, second_fd, second)

                with mock.patch.object(
                    checker, "exchange_paths", side_effect=change_candidate
                ):
                    result = self.run_in_process("--fix", "--add-missing")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(path.read_bytes(), original)
                self.assertIn("recovery files retained", result.stderr)
                self.assertNotIn("Updated oss/example.c", result.stdout)

    def test_unsupported_exchange_never_falls_back_to_replace(self) -> None:
        original = b"int original;\n"
        path = self.track("oss/example.c", original)
        with mock.patch.object(
            checker,
            "exchange_paths",
            side_effect=OSError(errno.ENOSYS, "exchange unavailable"),
        ), mock.patch.object(
            os, "replace", side_effect=AssertionError("unsafe fallback")
        ):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exchange unavailable", result.stderr)
        self.assertEqual(path.read_bytes(), original)

    def test_successful_exchange_leaves_no_recovery_directory(self) -> None:
        path = self.track("oss/example.c", b"int original;\n")
        result = self.run_cli("--fix", "--add-missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(COPYRIGHT.encode(), path.read_bytes())
        self.assertEqual(list(path.parent.glob(".copyright-*")), [])

    def test_staging_cleanup_failure_does_not_claim_retained_payload(self) -> None:
        original = b"int original;\n"
        path = self.track("oss/example.c", original)
        with mock.patch.object(
            os,
            "rmdir",
            side_effect=PermissionError(
                errno.EACCES, "simulated staging cleanup failure"
            ),
        ):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("simulated staging cleanup failure", result.stderr)
        self.assertIn(
            "source update installed, but cleanup or durability failed", result.stderr
        )
        self.assertNotIn("recovery files retained", result.stderr)
        self.assertNotIn("Updated oss/example.c", result.stdout)
        self.assertEqual(path.read_bytes(), normalize(path, original, True)[0])
        staging = list(path.parent.glob(".copyright-*"))
        self.assertEqual(len(staging), 1)
        self.assertEqual(list(staging[0].iterdir()), [])

    def test_final_sync_failure_does_not_report_deleted_recovery_directory(
        self,
    ) -> None:
        original = b"int original;\n"
        path = self.track("oss/example.c", original)
        fsync = os.fsync

        def fail_after_staging_removal(fd: int) -> None:
            if not list(path.parent.glob(".copyright-*")):
                raise OSError(errno.EIO, "simulated final sync failure")
            fsync(fd)

        with mock.patch.object(os, "fsync", side_effect=fail_after_staging_removal):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("simulated final sync failure", result.stderr)
        self.assertIn(
            "source update installed, but cleanup or durability failed", result.stderr
        )
        self.assertNotIn("recovery files retained", result.stderr)
        self.assertNotIn("(deleted)", result.stderr)
        self.assertNotIn("Updated oss/example.c", result.stdout)
        self.assertEqual(path.read_bytes(), normalize(path, original, True)[0])
        self.assertEqual(list(path.parent.glob(".copyright-*")), [])

    def test_parent_swap_between_stat_and_open_is_rejected(self) -> None:
        path = self.track("oss/module/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)
            open_file = os.open
            raced: list[bool] = []

            def swap_parent(
                name: str | Path,
                flags: int,
                mode: int = 0o777,
                *,
                dir_fd: int | None = None,
            ) -> int:
                if name == "module" and not raced:
                    raced.append(True)
                    path.parent.rename(self.root / "parked")
                    path.parent.symlink_to(directory, target_is_directory=True)
                return open_file(name, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(os, "open", side_effect=swap_parent):
                result = self.run_in_process("--fix", "--add-missing")
            self.assertTrue(raced)
            self.assertEqual(result.returncode, 1)
            self.assertIn("symlink", result.stderr)
            self.assertEqual(target.read_bytes(), original)

    def test_leaf_swap_between_stat_and_open_is_rejected(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "example.c"
            original = b"int untouched;\n"
            target.write_bytes(original)
            open_file = os.open
            raced: list[bool] = []

            def swap_leaf(
                name: str | Path,
                flags: int,
                mode: int = 0o777,
                *,
                dir_fd: int | None = None,
            ) -> int:
                if name == "example.c" and not raced:
                    raced.append(True)
                    path.unlink()
                    path.symlink_to(target)
                return open_file(name, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(os, "open", side_effect=swap_leaf):
                with self.assertRaisesRegex(ValueError, "symlink"):
                    with checker.source_file(self.root, Path("oss/example.c")):
                        self.fail("a replaced leaf was opened")
            self.assertTrue(raced)
            self.assertEqual(target.read_bytes(), original)

    def test_preexisting_temporary_name_is_not_deleted_or_modified(self) -> None:
        original = b"int original;\n"
        path = self.track("oss/example.c", original)
        collision = path.parent / ".copyright-collision"
        collision.write_bytes(b"unrelated contents")
        with mock.patch.object(secrets, "token_hex", return_value="collision"):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(collision.read_bytes(), b"unrelated contents")

    def test_partial_write_failure_keeps_the_original_and_cleans_temporary_file(
        self,
    ) -> None:
        original = b"#!/bin/sh\nprintf unchanged\n"
        path = self.track("oss/example.sh", original)
        path.chmod(0o755)
        write = os.write
        calls = []

        def fail_after_partial_write(fd: int, data: memoryview) -> int:
            calls.append(True)
            if len(calls) == 1:
                return write(fd, data[:10])
            raise OSError(errno.ENOSPC, "simulated full filesystem")

        with mock.patch.object(os, "write", side_effect=fail_after_partial_write):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("simulated full filesystem", result.stderr)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(path.parent.glob(".copyright-*")), [])

    def test_atomic_update_preserves_file_metadata(self) -> None:
        path = self.track("oss/example.sh", b"#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        os.setxattr(path, "user.copyright_review", b"preserved attribute")
        original = path.stat()
        result = self.run_cli("--fix", "--add-missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.stat().st_mode, original.st_mode)
        self.assertEqual(path.stat().st_uid, original.st_uid)
        self.assertEqual(path.stat().st_gid, original.st_gid)
        self.assertEqual(
            os.getxattr(path, "user.copyright_review"), b"preserved attribute"
        )

    def test_metadata_copy_failure_does_not_replace_the_original(self) -> None:
        original = b"#!/bin/sh\nexit 0\n"
        path = self.track("oss/example.sh", original)
        os.setxattr(path, "user.copyright_review", b"preserved attribute")
        with mock.patch.object(
            os, "setxattr", side_effect=PermissionError("cannot preserve attributes")
        ):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot preserve attributes", result.stderr)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(
            os.getxattr(path, "user.copyright_review"), b"preserved attribute"
        )
        self.assertEqual(list(path.parent.glob(".copyright-*")), [])

    def test_concurrent_content_edit_is_not_overwritten(self) -> None:
        path = self.track("oss/example.c", b"int initial;\n")
        edited = b"int edited_by_another_writer;\n"

        def edit_during_normalization(
            source: Path, data: bytes, add_missing: bool
        ) -> tuple[bytes, bool]:
            updated = normalize(source, data, add_missing)
            path.write_bytes(edited)
            return updated

        with mock.patch.object(
            checker, "normalize", side_effect=edit_during_normalization
        ):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("changed during processing", result.stderr)
        self.assertEqual(path.read_bytes(), edited)

    def test_unsafe_relative_source_paths_are_rejected(self) -> None:
        for path in (Path(), Path("../outside.c"), self.root / "absolute.c"):
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "relative"):
                    with checker.source_file(self.root, path):
                        self.fail("invalid source path was opened")

    def test_nonregular_leaf_is_rejected_before_open(self) -> None:
        path = self.track("oss/example.c", b"int example;\n")
        path.unlink()
        os.mkfifo(path)
        with mock.patch.object(os, "open", wraps=os.open) as opened:
            with self.assertRaisesRegex(ValueError, "expected a regular file"):
                with checker.source_file(self.root, Path("oss/example.c")):
                    self.fail("FIFO was opened as source")
        self.assertNotIn("example.c", [call.args[0] for call in opened.call_args_list])

    def test_unsupported_filesystem_primitives_fail_explicitly(self) -> None:
        self.track("oss/example.c", b"int example;\n")
        with mock.patch.object(checker, "SAFE_SOURCE_IO", False):
            result = self.run_in_process("--fix", "--add-missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("use the devcontainer", result.stderr)

    def test_invalid_mode_and_empty_scope_fail(self) -> None:
        self.assertNotEqual(self.run_cli("--add-missing").returncode, 0)
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no tracked OSS source files", result.stderr)

    def test_noncanonical_header_fails_check_without_writing(self) -> None:
        original = f"-- {COPYRIGHT} All rights reserved.\nSELECT 1;\n".encode()
        path = self.track("oss/example.sql", original)
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("noncanonical", result.stderr)
        self.assertEqual(path.read_bytes(), original)

    def test_language_filter_does_not_touch_later_migration_stages(self) -> None:
        shell = self.track("oss/script.sh", b"#!/bin/sh\nexit 0\n")
        makefile = self.track("oss/Makefile", b"all:\n\t@echo hello\n")
        python = self.track("oss/example.py", b"value = 1\n")
        sql = self.track("oss/example.sql", b"SELECT 1;\n")
        result = self.run_cli(
            "--fix", "--add-missing", "--languages", "shell", "makefile"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 2 files", result.stdout)
        self.assertIn(COPYRIGHT.encode(), shell.read_bytes())
        self.assertIn(COPYRIGHT.encode(), makefile.read_bytes())
        self.assertEqual(python.read_bytes(), b"value = 1\n")
        self.assertEqual(sql.read_bytes(), b"SELECT 1;\n")
        self.assertEqual(self.run_cli("--languages", "shell", "makefile").returncode, 0)
        self.assertEqual(self.run_cli().returncode, 1)

    def test_python_and_makefile_discovery(self) -> None:
        names = (
            "oss/example.py",
            "oss/types.pyi",
            "oss/Makefile",
            "oss/Makefile.global",
            "oss/Makefile.toml",
            "oss/GNUmakefile",
            "oss/makefile",
            "oss/rules.mk",
        )
        for name in names:
            self.track(name, b"")
        self.track("oss/scripts/runner", b"#!/usr/bin/env python3\npass\n")
        result = self.run_cli(
            "--fix", "--add-missing", "--languages", "python", "makefile"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 9 files", result.stdout)
        self.assertEqual(
            self.run_cli("--languages", "python", "makefile").returncode, 0
        )

    def test_unknown_and_empty_language_selections_fail(self) -> None:
        self.track("oss/example.c", b"int example;\n")
        self.assertNotEqual(self.run_cli("--languages", "unknown").returncode, 0)
        self.assertNotEqual(self.run_cli("--languages").returncode, 0)
        result = self.run_cli("--languages", "python")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no tracked OSS source files", result.stderr)


if __name__ == "__main__":
    unittest.main()
