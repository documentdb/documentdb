#!/usr/bin/env python3
"""
Detect extern variable declarations in .c files that are never referenced
elsewhere in the same file. Such declarations are dead code — the variable
was likely used at some point but the usage was removed while the extern
declaration was left behind.

Usage:
    python3 scripts/check_unused_externs.py [--check] [directories...]

Options:
    --check        Exit with non-zero status if issues are found (for CI).
    directories    Directories to scan (default: oss/ pgmongo/).

Examples:
    python3 scripts/check_unused_externs.py                            # report only
    python3 scripts/check_unused_externs.py --check                    # CI gate
    python3 scripts/check_unused_externs.py oss/pg_documentdb/src/     # scan one dir
"""

import os
import re
import sys

# Matches lines like:
#   extern bool EnableFoo;
#   extern int *BarCount;
#   extern const char *BazName;
# Captures the variable name (last identifier before the semicolon).
# Excludes function declarations — those have parentheses before the semicolon.
EXTERN_VAR_RE = re.compile(
    r"^extern\s+"       # starts with 'extern'
    r"(?:const\s+)?"    # optional 'const' qualifier
    r"\w[\w\s]*?"       # type name (e.g. 'bool', 'unsigned int')
    r"\s+\*?\s*"        # optional pointer star
    r"(\w+)\s*;"        # variable name, then semicolon
)


def find_unused_externs(directories):
    """
    Scan .c files for extern variable declarations whose name does not appear
    on any other line of the same file. Yields (path, line_number, name, text).
    """
    for directory in directories:
        for root, _dirs, files in os.walk(directory):
            for fname in files:
                if not fname.endswith(".c"):
                    continue

                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, encoding="utf-8", errors="replace") as f:
                        lines = f.readlines()
                except OSError:
                    continue

                # Pass 1: collect all extern variable declarations in this file.
                externs = []
                for i, line in enumerate(lines):
                    m = EXTERN_VAR_RE.match(line.strip())
                    if m:
                        externs.append((i, m.group(1), line.strip()))

                if not externs:
                    continue

                # Pass 2: for each declaration, check whether the variable name
                # appears on any other line (word-boundary match).
                for decl_line, varname, decl_text in externs:
                    pat = re.compile(r"\b" + re.escape(varname) + r"\b")
                    used = any(
                        pat.search(lines[i])
                        for i in range(len(lines))
                        if i != decl_line
                    )
                    if not used:
                        yield (fpath, decl_line + 1, varname, decl_text)


def main():
    check_mode = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--check"]
    directories = args if args else ["oss/", "pgmongo/"]

    for d in directories:
        if not os.path.isdir(d):
            print(f"Warning: directory '{d}' not found, skipping.", file=sys.stderr)

    unused = list(find_unused_externs(directories))

    if not unused:
        print("No unused extern declarations found.")
        return

    print(f"Found {len(unused)} unused extern declaration(s):\n")
    for fpath, lineno, varname, decl_text in unused:
        print(f"  {fpath}:{lineno}: {varname}")
        print(f"    {decl_text}\n")

    if check_mode:
        print("ERROR: Unused extern declarations found. Remove them or use them.")
        sys.exit(1)


if __name__ == "__main__":
    main()
