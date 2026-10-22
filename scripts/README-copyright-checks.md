# Copyright header tooling

Run from the DocumentDB source root in the Linux devcontainer with Python 3.8 or newer:

```sh
python3 scripts/check_oss_copyright.py --check
python3 scripts/check_oss_copyright.py --languages shell makefile
python3 scripts/check_oss_copyright.py --fix
```

The default source root is the directory containing `scripts/`, independent of
the current working directory. `--root` selects another source directory.
Only Git-tracked files within that directory are considered, including
extensionless Shell and Python scripts. `--languages` restricts checking or
fixing to the named languages.

`--fix` normalizes existing Microsoft notices. Use `--fix --add-missing` only
after confirming Microsoft authorship of files without notices. Third-party
notices are preserved; conflicting license declarations require manual review.

Fixes use no-follow directory descriptors and Linux atomic exchange. On a
publication conflict, the command fails and reports retained recovery files.
Inspect both the source and recovery directory before retrying or deleting
anything: a save racing with rollback can leave the newest version in recovery.
Cleanup or durability failures after publication are reported separately.

## Tool maintenance

```sh
python3 -m pip install -r scripts/requirements-copyright-checks.txt
python3 -m mypy --strict --python-version 3.8 scripts/check_oss_copyright.py scripts/test_check_oss_copyright.py
python3 -m black --check --target-version py38 scripts/check_oss_copyright.py scripts/test_check_oss_copyright.py
python3 scripts/test_check_oss_copyright.py -v
```

The copyright workflow runs these quality gates on Python 3.8 and 3.12.
During a staged migration, source enforcement is enabled per language as its
headers are normalized. Do not replace the workflow's selected languages with
an unrestricted check until the remaining source batches are ready.
