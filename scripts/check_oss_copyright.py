#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Check or normalize Microsoft notices in tracked OSS source headers."""

from __future__ import annotations

import argparse
import ast
from collections.abc import Iterator, Sequence
from contextlib import contextmanager, ExitStack
import ctypes
import errno
import io
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tokenize
from typing import Literal, Tuple


SourceLanguage = Literal["c", "rust", "sql", "shell", "python", "makefile"]
CommentStyle = Literal["block", "doc-block", "line", "///", "//!"]
DirectoryHandle = Tuple[int, str, int]

COPYRIGHT = "Copyright (c) Microsoft Corporation."
LICENSE = "Licensed under the MIT License"
SUFFIX_LANGUAGES: dict[str, SourceLanguage] = {
    ".c": "c",
    ".h": "c",
    ".rs": "rust",
    ".sql": "sql",
    ".sh": "shell",
    ".bash": "shell",
    ".py": "python",
    ".pyi": "python",
    ".mk": "makefile",
}
LANGUAGES = sorted(set(SUFFIX_LANGUAGES.values()))
SAFE_SOURCE_IO = all(
    operation in os.supports_dir_fd
    for operation in (os.open, os.stat, os.unlink, os.rename)
) and all(
    hasattr(os, name)
    for name in (
        "O_NOFOLLOW",
        "O_DIRECTORY",
        "listxattr",
        "getxattr",
        "setxattr",
        "removexattr",
    )
)
SHELL_SHEBANG = re.compile(rb"^#![^\r\n]*\b(?:bash|sh|dash|ksh|zsh)\b")
PYTHON_SHEBANG = re.compile(rb"^#![^\r\n]*\bpython(?:[23](?:\.\d+)?)?\b")
PYTHON_ENCODING = re.compile(r"^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+")
MICROSOFT_NOTICE = re.compile(
    r"^(?P<prefix>[ \t]*(?:\*[ \t]?)?)"
    r"(?P<notice>(?:Portions )?Copyright \(c\) Microsoft Corporation\.)"
    r"(?:[ \t]+All rights reserved\.)?[ \t]*$",
    re.MULTILINE,
)
MIT_LINES = re.compile(
    r"^[ \t]*(?:\*[ \t]?)?"
    r"(?:Licensed under the MIT License\.?|SPDX-License-Identifier: MIT|"
    r"This source code is licensed under the MIT license found in the|"
    r"LICENSE file in the root directory of this source tree\.)[ \t]*(?:\n|$)",
    re.MULTILINE,
)
COPYRIGHT_NOTICE = re.compile(
    r"^[ \t]*(?:\*[ \t]*)?(?:Portions[ \t]+)?Copyright\b",
    re.IGNORECASE | re.MULTILINE,
)
MICROSOFT_OWNER = re.compile(r"\bMicrosoft[ \t]+Corporation\b", re.IGNORECASE)


def copyright_notices(body: str) -> list[str]:
    return [line for line in io.StringIO(body) if COPYRIGHT_NOTICE.match(line)]


def validate_licenses(body: str) -> None:
    for declaration in re.findall(r"SPDX-License-Identifier:[ \t]*([^\n]*)", body):
        if declaration.strip() != "MIT":
            raise ValueError(
                "non-MIT SPDX identifier or expression; review the license manually"
            )
    for line in io.StringIO(body):
        content = re.sub(r"^[ \t]*(?:\*[ \t]?)?", "", line).strip()
        if content.lower().startswith("licensed under ") and content not in {
            LICENSE,
            LICENSE + ".",
        }:
            raise ValueError("unrecognized license declaration; review it manually")


def source_language(path: Path, first_line: bytes = b"") -> SourceLanguage | None:
    if path.suffix in SUFFIX_LANGUAGES:
        return SUFFIX_LANGUAGES[path.suffix]
    if path.name in {"Makefile", "makefile", "GNUmakefile"} or path.name.startswith(
        "Makefile."
    ):
        return "makefile"
    if not path.suffix:
        if SHELL_SHEBANG.match(first_line):
            return "shell"
        if PYTHON_SHEBANG.match(first_line):
            return "python"
    return None


def open_nofollow(name: str, flags: int, parent_fd: int) -> int:
    mode = os.stat(name, dir_fd=parent_fd, follow_symlinks=False).st_mode
    if stat.S_ISLNK(mode):
        raise ValueError(f"symlink path component: {name}")
    if flags & os.O_DIRECTORY:
        if not stat.S_ISDIR(mode):
            raise ValueError(f"{name}: expected a directory")
    elif not stat.S_ISREG(mode):
        raise ValueError(f"{name}: expected a regular file")
    try:
        return os.open(name, flags | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError as error:
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise ValueError(
                f"symlink or non-directory path component: {name}"
            ) from error
        raise


@contextmanager
def source_file(
    root: Path, path: Path
) -> Iterator[tuple[int, int, os.stat_result, list[DirectoryHandle]]]:
    if not SAFE_SOURCE_IO:
        raise ValueError(
            "safe source access requires POSIX directory descriptors; use the devcontainer"
        )
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError("source path must be relative to the repository")
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as stack:
        parent_fd = os.open(root, directory_flags)
        stack.callback(os.close, parent_fd)
        directories: list[DirectoryHandle] = []
        for part in path.parts[:-1]:
            directory_fd = open_nofollow(part, directory_flags, parent_fd)
            stack.callback(os.close, directory_fd)
            directories.append((parent_fd, part, directory_fd))
            parent_fd = directory_fd
        source_fd = open_nofollow(path.name, os.O_RDONLY | os.O_NONBLOCK, parent_fd)
        stack.callback(os.close, source_fd)
        snapshot = os.fstat(source_fd)
        if not stat.S_ISREG(snapshot.st_mode):
            raise ValueError(f"{path}: expected a regular file")
        yield parent_fd, source_fd, snapshot, directories


def read_source(source_fd: int, limit: int | None = None) -> bytes:
    if limit is not None:
        return os.read(source_fd, limit)
    chunks = []
    while chunk := os.read(source_fd, 65536):
        chunks.append(chunk)
    return b"".join(chunks)


def source_fingerprint(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        info.st_mode,
        info.st_uid,
        info.st_gid,
    )


def verify_source(
    parent_fd: int,
    source_fd: int,
    snapshot: os.stat_result,
    directories: Sequence[DirectoryHandle],
    name: str,
) -> None:
    for ancestor_fd, component, directory_fd in directories:
        current = os.stat(component, dir_fd=ancestor_fd, follow_symlinks=False)
        if stat.S_ISLNK(current.st_mode):
            raise ValueError(f"symlink path component: {component}")
        opened = os.fstat(directory_fd)
        if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError("source directory changed during processing")
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if source_fingerprint(current) != source_fingerprint(snapshot) or (
        source_fingerprint(os.fstat(source_fd)) != source_fingerprint(snapshot)
    ):
        raise ValueError("source file changed during processing")


def extended_attributes(fd: int) -> dict[str, bytes]:
    try:
        names = os.listxattr(fd)
    except OSError as error:
        if error.errno == errno.EOPNOTSUPP:
            # This filesystem cannot carry extended attributes.
            return {}
        raise
    return {name: os.getxattr(fd, name) for name in names}


def exchange_paths(
    first_fd: int, first_name: str, second_fd: int, second_name: str
) -> None:
    try:
        renameat2 = ctypes.CDLL(None, use_errno=True).renameat2
    except AttributeError as error:
        raise ValueError(
            "safe fixes require Linux renameat2; use the devcontainer"
        ) from error
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    if renameat2(
        first_fd, os.fsencode(first_name), second_fd, os.fsencode(second_name), 2
    ):
        code = ctypes.get_errno()
        raise OSError(code, "atomic exchange failed: " + os.strerror(code))


def exchanged_fingerprint(info: os.stat_result) -> tuple[int, ...]:
    # renameat2 changes ctime; all other saved identity/content metadata must match.
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_mode,
        info.st_uid,
        info.st_gid,
    )


def verify_exchanged_file(
    directory_fd: int,
    name: str,
    fd: int,
    snapshot: os.stat_result,
    content: bytes,
    attributes: dict[str, bytes],
) -> None:
    expected = exchanged_fingerprint(snapshot)
    if (
        exchanged_fingerprint(os.stat(name, dir_fd=directory_fd, follow_symlinks=False))
        != expected
    ):
        raise ValueError("exchanged file changed during publication")
    os.lseek(fd, 0, os.SEEK_SET)
    if (
        read_source(fd) != content
        or extended_attributes(fd) != attributes
        or exchanged_fingerprint(os.fstat(fd)) != expected
    ):
        raise ValueError("exchanged content or metadata changed during publication")


def replace_source(
    parent_fd: int,
    source_fd: int,
    snapshot: os.stat_result,
    directories: Sequence[DirectoryHandle],
    name: str,
    original: bytes,
    updated: bytes,
) -> None:
    verify_source(parent_fd, source_fd, snapshot, directories, name)
    staging_name = ".copyright-" + secrets.token_hex(16)
    os.mkdir(staging_name, 0o700, dir_fd=parent_fd)
    with ExitStack() as stack:
        staging_fd = open_nofollow(
            staging_name, os.O_RDONLY | os.O_DIRECTORY, parent_fd
        )
        stack.callback(os.close, staging_fd)
        staging_snapshot = os.fstat(staging_fd)
        retain_recovery = False
        recovery_payload_removed = False
        temporary_info: os.stat_result | None = None
        try:
            temporary_fd = os.open(
                "payload",
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=staging_fd,
            )
            stack.callback(os.close, temporary_fd)
            temporary_info = os.fstat(temporary_fd)
            remaining = memoryview(updated)
            while remaining:
                written = os.write(temporary_fd, remaining)
                if written == 0:
                    raise OSError("could not finish writing copyright update")
                remaining = remaining[written:]
            if (temporary_info.st_uid, temporary_info.st_gid) != (
                snapshot.st_uid,
                snapshot.st_gid,
            ):
                os.fchown(temporary_fd, snapshot.st_uid, snapshot.st_gid)
            os.fchmod(temporary_fd, stat.S_IMODE(snapshot.st_mode))
            original_attributes = extended_attributes(source_fd)
            temporary_attributes = extended_attributes(temporary_fd)
            for attribute in temporary_attributes.keys() - original_attributes.keys():
                os.removexattr(temporary_fd, attribute)
            for attribute, value in original_attributes.items():
                if temporary_attributes.get(attribute) != value:
                    os.setxattr(temporary_fd, attribute, value)
            os.fsync(temporary_fd)
            verify_source(parent_fd, source_fd, snapshot, directories, name)
            candidate_snapshot = os.fstat(temporary_fd)
            verify_exchanged_file(
                staging_fd,
                "payload",
                temporary_fd,
                candidate_snapshot,
                updated,
                original_attributes,
            )
            os.fsync(staging_fd)
            retain_recovery = True
            exchange_paths(staging_fd, "payload", parent_fd, name)
            try:
                verify_source(
                    parent_fd, temporary_fd, os.fstat(temporary_fd), directories, name
                )
                verify_exchanged_file(
                    staging_fd,
                    "payload",
                    source_fd,
                    snapshot,
                    original,
                    original_attributes,
                )
                verify_exchanged_file(
                    parent_fd,
                    name,
                    temporary_fd,
                    candidate_snapshot,
                    updated,
                    original_attributes,
                )
                os.fsync(parent_fd)
                os.fsync(staging_fd)
            except (OSError, ValueError) as error:
                try:
                    # Exchange again: preserve an intervening save in the recovery entry.
                    exchange_paths(staging_fd, "payload", parent_fd, name)
                    os.fsync(parent_fd)
                    os.fsync(staging_fd)
                except (OSError, ValueError) as rollback_error:
                    raise ValueError(
                        f"{error}; rollback failed: {rollback_error}"
                    ) from error
                raise ValueError(f"{error}; publication rolled back") from error
            verify_exchanged_file(
                staging_fd,
                "payload",
                source_fd,
                snapshot,
                original,
                original_attributes,
            )
            os.unlink("payload", dir_fd=staging_fd)
            recovery_payload_removed = True
            os.rmdir(staging_name, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except (OSError, ValueError) as error:
            if recovery_payload_removed:
                raise ValueError(
                    f"source update installed, but cleanup or durability failed: {error}"
                ) from error
            if retain_recovery:
                recovery_path = os.readlink(f"/proc/self/fd/{staging_fd}")
                raise ValueError(
                    f"{error}; recovery files retained at {recovery_path}"
                ) from error
            entries = os.listdir(staging_fd)
            if entries == ["payload"]:
                info = os.stat("payload", dir_fd=staging_fd, follow_symlinks=False)
                if temporary_info is not None and (info.st_dev, info.st_ino) == (
                    temporary_info.st_dev,
                    temporary_info.st_ino,
                ):
                    os.unlink("payload", dir_fd=staging_fd)
            if not os.listdir(staging_fd):
                current = os.stat(staging_name, dir_fd=parent_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == (
                    staging_snapshot.st_dev,
                    staging_snapshot.st_ino,
                ):
                    os.rmdir(staging_name, dir_fd=parent_fd)
            else:
                recovery_path = os.readlink(f"/proc/self/fd/{staging_fd}")
                raise ValueError(
                    f"{error}; recovery files retained at {recovery_path}"
                ) from error
            raise


def source_files(
    root: Path, languages: Sequence[SourceLanguage] | None = None
) -> list[Path]:
    selected = set(LANGUAGES if languages is None else languages)
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--stage", "-z", "--", "."],
        check=True,
        capture_output=True,
    )
    paths = []
    for entry in result.stdout.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, _, stage = metadata.split()
        path = Path(name.decode("utf-8"))
        if stage != b"0":
            raise ValueError(f"{path}: unresolved index conflict")
        if mode not in {b"100644", b"100755"}:
            continue
        try:
            with source_file(root, path) as (
                _parent_fd,
                source_fd,
                _snapshot,
                _directories,
            ):
                language = source_language(path)
                if language is None and not path.suffix:
                    language = source_language(path, read_source(source_fd, 256))
        except FileNotFoundError:
            continue  # Unstaged deletions have no working-tree content to check.
        if language in selected:
            paths.append(path)
    if not paths:
        raise ValueError("no tracked OSS source files found for the selected languages")
    return sorted(set(paths))


def leading_comments(
    text: str, marker: str, start: int
) -> Iterator[tuple[int, int, CommentStyle]]:
    """Yield only comments before the first source statement or directive."""
    position = start
    while position < len(text):
        position += len(text[position:]) - len(text[position:].lstrip())
        if text.startswith("/*", position) and marker != "#":
            end = text.find("*/", position + 2)
            if end == -1:
                raise ValueError("unterminated leading block comment")
            if "/*" in text[position + 2 : end]:
                raise ValueError("nested leading block comment; review it manually")
            end += 2
            yield position, end, "block"
        elif text.startswith(marker, position):
            style = line_comment_style(text, position, marker)
            end = position
            while (
                text.startswith(marker, end)
                and line_comment_style(text, end, marker) == style
            ):
                newline = text.find("\n", end)
                end = len(text) if newline == -1 else newline + 1
            yield position, end, style
        else:
            break
        position = end


def line_comment_style(text: str, position: int, marker: str) -> CommentStyle:
    if marker == "//":
        if text.startswith("//!", position):
            return "//!"
        if text.startswith("///", position) and not text.startswith("////", position):
            return "///"
    return "line"


def comment_body(comment: str, style: CommentStyle, marker: str) -> str:
    if style not in {"block", "doc-block"}:
        prefix = marker if style == "line" else style
        lines = (line[len(prefix) :] for line in io.StringIO(comment))
        return "".join(line[1:] if line.startswith(" ") else line for line in lines)
    if style == "doc-block":
        return comment[3:-2]
    return comment[2:-2]


def normalize_comment(
    comment: str, style: CommentStyle, marker: str, c_source: bool
) -> str:
    body = comment_body(comment, style, marker)
    # A compact legacy notice can share its line with the MIT identifier.
    body = re.sub(
        r"(?<=Corporation\.)[ \t]+SPDX-License-Identifier: MIT[ \t]*$",
        "\nSPDX-License-Identifier: MIT",
        body,
    )
    if not MICROSOFT_NOTICE.search(body):
        if any(MICROSOFT_OWNER.search(line) for line in copyright_notices(body)):
            raise ValueError("unrecognized Microsoft notice; review it manually")
        return comment
    validate_licenses(body)
    if any(not MICROSOFT_OWNER.search(line) for line in copyright_notices(body)):
        lines = []
        microsoft_metadata = False
        for line in io.StringIO(body):
            if COPYRIGHT_NOTICE.match(line):
                microsoft_metadata = bool(MICROSOFT_OWNER.search(line))
            elif MIT_LINES.fullmatch(line):
                if microsoft_metadata:
                    continue
            elif line.strip(" \t*\n"):
                microsoft_metadata = False
            lines.append(line)
        body = "".join(lines)
    else:
        body = MIT_LINES.sub("", body)
    license_text = LICENSE if c_source else LICENSE + "."
    body = MICROSOFT_NOTICE.sub(
        lambda match: (
            match["prefix"] + match["notice"] + "\n" + match["prefix"] + license_text
        ),
        body,
    )
    if c_source and style == "block" and "\n" in comment:
        return "/*" + body + "*/"
    if style == "block":
        lines = [re.sub(r"^[ \t]*\* ?", "", line).strip() for line in io.StringIO(body)]
        while lines and (not lines[0] or set(lines[0]) == {"-"}):
            lines.pop(0)
        while lines and (not lines[-1] or set(lines[-1]) == {"-"}):
            lines.pop()
    else:
        lines = [
            line[:-1] if line.endswith("\n") else line for line in io.StringIO(body)
        ]
    if c_source:
        return (
            "/*\n"
            + "".join(" *" + (" " + line if line else "") + "\n" for line in lines)
            + " */\n"
        )
    return "".join(marker + (" " + line if line else "") + "\n" for line in lines)


def python_docstring(text: str) -> str:
    expression: list[tuple[int, str]] = []
    for token in tokenize.generate_tokens(io.StringIO(text).readline):
        if not expression and token.type in {
            tokenize.COMMENT,
            tokenize.NL,
            tokenize.NEWLINE,
        }:
            continue
        if not expression and token.type != tokenize.STRING and token.string != "(":
            return ""
        if token.type in {tokenize.NEWLINE, tokenize.ENDMARKER} or token.string == ";":
            break
        expression.append((token.type, token.string))
    if expression:
        value = ast.parse(tokenize.untokenize(expression), mode="eval").body
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            return value.value
    return ""


def normalize(path: Path, data: bytes, add_missing: bool = False) -> tuple[bytes, bool]:
    bom = b"\xef\xbb\xbf" if data.startswith(b"\xef\xbb\xbf") else b""
    language = source_language(path, data[len(bom) :].split(b"\n", 1)[0])
    if language is None:
        raise ValueError("unsupported source language")
    encoding = "utf-8"
    encoding_lines = 0
    if language == "python":
        encoding, scanned_lines = tokenize.detect_encoding(io.BytesIO(data).readline)
        encoding_lines = len(scanned_lines)
        if encoding == "utf-8-sig":
            encoding = "utf-8"
    text = data[len(bom) :].decode(encoding)
    if text.encode(encoding) != data[len(bom) :]:
        raise ValueError("source encoding is not byte-preserving; review it manually")
    newline = "\r\n" if "\r\n" in text else "\n"
    without_crlf = text.replace("\r\n", "")
    if "\r" in without_crlf or (newline == "\r\n" and "\n" in without_crlf):
        raise ValueError("mixed line endings; review it manually")
    text = text.replace("\r\n", "\n")
    c_source = language == "c"
    marker = (
        "#"
        if language in {"shell", "python", "makefile"}
        else "--" if language == "sql" else "//"
    )
    preamble = []
    body_lines = []
    for index, line in enumerate(io.StringIO(text)):
        if (
            index == 0
            and language in {"shell", "python", "rust", "makefile"}
            and (
                line.startswith("#!")
                and not (language == "rust" and line.startswith("#!["))
            )
        ):
            preamble.append(line)
        elif (
            language == "python"
            and index < encoding_lines
            and PYTHON_ENCODING.match(line)
        ):
            preamble.append(line)
        else:
            body_lines.append(line)
    text = "".join(preamble + body_lines)
    start = sum(len(line) for line in preamble)
    comments = list(leading_comments(text, marker, start))
    has_notice = False
    has_microsoft = False
    document_notice = False
    header_bodies = []
    replacements = []
    for begin, end, style in comments:
        comment = text[begin:end]
        documentation = language == "rust" and (
            style in {"///", "//!"}
            or comment.startswith("/*!")
            or (comment.startswith("/**") and not comment.startswith("/***"))
        )
        body = comment_body(
            comment,
            "doc-block" if documentation and style == "block" else style,
            marker,
        )
        notices = copyright_notices(body)
        if not documentation or notices:
            header_bodies.append(body)
        if notices:
            has_notice = True
            if any(MICROSOFT_OWNER.search(line) for line in notices):
                if documentation:
                    document_notice = True
                else:
                    has_microsoft = True
                    replacement = normalize_comment(comment, style, marker, c_source)
                    if (
                        style == "block"
                        and text[end:].startswith("\n")
                        and replacement.endswith("\n")
                    ):
                        replacement = replacement[:-1]
                    replacements.append((begin, end, replacement))
    if language == "python":
        docstring = python_docstring(text[start:])
        notices = copyright_notices(docstring)
        if notices:
            has_notice = True
            header_bodies.append(docstring)
            document_notice = any(MICROSOFT_OWNER.search(line) for line in notices)
    if has_notice and not has_microsoft and not document_notice:
        return data, True
    for body in header_bodies:
        validate_licenses(body)
    if has_microsoft:
        header_only = not text[comments[-1][1] :].strip()
        for begin, end, replacement in reversed(replacements):
            text = text[:begin] + replacement + text[end:]
        if has_microsoft and header_only:
            text = text.rstrip() + "\n"
        return bom + text.replace("\n", newline).encode(encoding), False
    if not add_missing and not document_notice:
        raise ValueError(
            "missing copyright header; confirm authorship before using --fix --add-missing"
        )
    if c_source:
        header = f"/*\n * {COPYRIGHT}\n * {LICENSE}\n */\n\n"
    else:
        header = f"{marker} {COPYRIGHT}\n{marker} {LICENSE}.\n\n"
    if start and not text[:start].endswith("\n"):
        header = "\n" + header
    header_only = not text[start:].strip()
    text = text[:start] + header + text[start:]
    if header_only:
        text = text.rstrip() + "\n"
    return bom + text.replace("\n", newline).encode(encoding), False


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check", action="store_true", help="check without writing (default)"
    )
    mode.add_argument(
        "--fix", action="store_true", help="normalize existing Microsoft headers"
    )
    parser.add_argument(
        "--add-missing",
        action="store_true",
        help="with --fix, confirm Microsoft authorship of files without a copyright notice",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="source tree root (defaults to the directory containing scripts/)",
    )
    parser.add_argument(
        "--languages",
        nargs="+",
        choices=LANGUAGES,
        help="limit checking or fixing to these languages (defaults to all)",
    )
    args = parser.parse_args(argv)
    if args.add_missing and not args.fix:
        parser.error("--add-missing requires --fix and confirmed Microsoft authorship")
    try:
        args.root = args.root.resolve(strict=True)
        paths = source_files(args.root, args.languages)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Copyright check failed: {error}", file=sys.stderr)
        return 1
    failures = changed = third_party = 0
    for path in paths:
        try:
            with source_file(args.root, path) as (
                parent_fd,
                source_fd,
                snapshot,
                directories,
            ):
                original = read_source(source_fd)
                verify_source(parent_fd, source_fd, snapshot, directories, path.name)
                updated, preserved = normalize(path, original, args.add_missing)
                third_party += preserved
                if updated != original:
                    if args.fix:
                        replace_source(
                            parent_fd,
                            source_fd,
                            snapshot,
                            directories,
                            path.name,
                            original,
                            updated,
                        )
                        changed += 1
                        print(f"Updated {path}")
                    else:
                        failures += 1
                        print(
                            f"{path}: noncanonical Microsoft header (run with --fix)",
                            file=sys.stderr,
                        )
        except (
            OSError,
            UnicodeError,
            ValueError,
            SyntaxError,
            tokenize.TokenError,
        ) as error:
            failures += 1
            print(f"{path}: {error}", file=sys.stderr)
    print(
        f"Checked {len(paths)} files; updated {changed}; "
        f"preserved {third_party} third-party-only headers; errors {failures}."
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
