# Engine Onboarding (OSS)

This guide is for contributors working on the OSS engine extensions.
It focuses on backend extension development and testing in:

- `pg_documentdb_core`
- `pg_documentdb`
- `pg_documentdb_extended_rum`

## Quickstart: Use the Dev Container

The OSS repo includes a ready-to-use VS Code dev container.
Use it as the fastest path to a consistent local environment.

1. Open the repository root in VS Code.
2. Install the Dev Containers extension if prompted.
3. Run Dev Containers: Reopen in Container from the Command Palette.
4. Wait for the image build to complete. The first build can take a while.

The container forwards:

- `9712` for PostgreSQL
- `10260` for gateway testing when needed

Preinstalled defaults from `devcontainer.json` include C/C++ tooling and
Rust tooling for gateway development.

## Build and Run

Build with `make` or `make clean && make`. For a debug build, run `make DEBUG=yes`.
Then install locally built binaries into PostgreSQL with `sudo make install`.
Finally, run backend PostgreSQL tests with `make check`.

### Working with the Intel Decimal Floating Point Math Library

If the Intel math library is not installed, run
`scripts/install_setup_intel_decimal_math_lib.sh` from inside the container.
You can override the install location with `DESTINSTALLDIR`.
Otherwise, `/usr` is used.

Note:
If you are not using the dev container, add
`$DESTINSTALLDIR/lib/pkgconfig` to `PKG_CONFIG_PATH` before building.
You will also need to set the environment variable `INSTALL_DEPENDENCIES_ROOT`
to a location for downloading a creating the artifacts.

The library is built with DocumentDB via `PG_CPPFLAGS` in `Makefile`
using these defaults:

- `DECIMAL_CALL_BY_REFERENCE 0` passes parameters by value to
  library functions.
- `DECIMAL_GLOBAL_ROUNDING 0` requires explicit rounding mode
  parameters for Decimal128 operations.
- `DECIMAL_GLOBAL_EXCEPTION_FLAGS 0` requires explicit exception flag
  parameters for Decimal128 operations.

For details, refer to
`/root/IntelRDFPMathLib20U2/lib64/intelmathlib/README` in the local
dev container.

### Working with the PCRE2 Library

If the PCRE2 library is not installed, run `scripts/install_setup_pcre2.sh`.
You can override the install location with `DESTINSTALLDIR`.
Otherwise, `/usr` is used.

Note:
If you are not using the dev container, add
`$DESTINSTALLDIR/lib/pkgconfig` to `PKG_CONFIG_PATH` before building.
You will also need to set the environment variable `INSTALL_DEPENDENCIES_ROOT`
to a location for downloading a creating the artifacts.

### Running an Ad Hoc PostgreSQL Server and Queries

1. Run `make` and then `sudo make install`.
2. Set up a PostgreSQL instance with
   `scripts/start_oss_server.sh [-d <pathToDB>]`.
   Example: `scripts/start_oss_server.sh -d ~/.documentdb/data`.

   - To reset data and rerun from scratch, rerun
     `scripts/start_oss_server.sh -c -d <pathToDB>`.
   - If you made code changes, rerun `sudo make install` first.
   - If a path is not provided, the default is `~/.documentdb/data`.
   - For first-time setup, use `-c` for a clean run.

3. Connect with `psql -d postgres -p 9712`.

Note:
The `-n` option is optional. The default is `0`,
which runs a single-node cluster.
See the next section for multi-node usage.

### Running an Ad Hoc Multi-Node PostgreSQL Server

You can run coordinator plus worker nodes using the `-n` argument on
`scripts/start_oss_server.sh`.
Without `-n`, only the coordinator node runs.

1. Start the server: `scripts/start_oss_server.sh -c -n 2`.
2. Connect to the coordinator: `psql -d postgres -p 9712`.

## Coding Style

- C formatting is enforced with `citus_indent`; run it before submitting
  changes.
- SQL-exported function names should be `snake_case`.
- Internal C function names should be `TitleCase`.
- Header files should live under `include/<relative-path>`.
- Source files should live under `src/<relative-path>`.
- Keep C file organization consistent:
  1. Copyright header
  2. Includes
  3. Type declarations (when needed)
  4. Static function declarations
  5. SQL-export declarations (`PG_FUNCTION_INFO_V1`)
  6. Exported function definitions
  7. Static function definitions
- Document function behavior, especially non-obvious constraints and
  invariants.

### Best Practices

- Avoid passing raw `true` or `false` literals to function calls.
  Use a clearly named boolean local variable.
- If a parameter is intentionally unused, name the local variable `ignore`
  for clarity.
- Use `palloc` or `palloc0` instead of `malloc`.
- Check whether `libbson` already provides a helper before implementing
  custom BSON mutation logic.
- Use `CHECK_FOR_INTERRUPTS()` in long-running loops and recursive flows.
- Use `check_stack_depth()` in recursive functions.

### SQL Changes

If you are making SQL changes, follow the guidance in the
[Citus onboarding guide](https://github.com/citusdata/citus/blob/main/CONTRIBUTING.md#making-sql-changes).
If an existing function is not factored into the UDF folder structure,
clean it up as part of your change.

## Testing

### Authoring Backend Tests

For tests under `pg_documentdb`, set both values at the top of the SQL
file and keep them identical:

```sql
SET documentdb.next_collection_id TO <NUMBER>;
SET documentdb.next_collection_index_id TO <NUMBER>;
```

### Input Coverage to Consider

When adding operator tests, enumerate complex cases and verify behavior
explicitly.
Add additional patterns to this list as needed.

1. Arrays of arrays
2. Documents of documents
3. Documents containing arrays
4. Arrays containing documents
5. Arrays containing documents with duplicate fields

```json
{
  "arr": [
    {
      "a": { "b": "c" }
    },
    {
      "a": { "b": "d" }
    }
  ]
}
```

6. A dotted path that cross-cuts arrays and objects

If an operator takes a dotted path like `a.b.c.d`, verify behavior for
cross-cutting path traversal.
Not all operators treat these paths uniformly.

```json
{
  "a": [
    {
      "b": [{ "c": { "d": 1 } }]
    },
    {
      "b": { "c": [{ "d": 1 }] }
    }
  ]
}
```

7. Stages or operators that take a path input

Test both simple dotted paths and cross-cutting dotted paths (see item 6).

8. Duplicate spec paths

```javascript
db.emptyCollection.updateOne(
  { myArray: 5 },
  { $set: { "myArray.$[]": 10 } },
  { $set: { "myArray.$[]": 10 } }
)
```

```javascript
db.emptyCollection.updateOne(
  { myArray: 5 },
  { $set: { "myArray.$[]": 10 }, $unset: { "myArray.$[]": 10 } }
)
```

### SQL EXPLAIN Tests

1. Use `EXPLAIN (costs off)` so tests are not flaky due to cost changes.
2. Use the following pattern when testing index usage on
   `<your_collection_name>`:

```sql
SELECT documentdb_distributed_test_helpers.drop_primary_key(
  'db',
  '<your_collection_name>'
);
BEGIN;
SET LOCAL enable_seqscan TO off;
EXPLAIN (costs off) <your_sql_query>;
ROLLBACK;
```

1. For distributed tables, explain output may include
   `Distributed Subplan <PlanId>`.
   Mask it with
   `documentdb_distributed_test_helpers.mask_plan_id_from_distributed_subplan`
   to avoid test flakiness.
   Subplan IDs auto-increment within a session.

## Docker Troubleshooting

- If Open Folder in Container fails with cannot start or connect to
  Docker, open Docker Settings and enable integration with additional
  distros.

- If you get this error:

```text
failed to solve with frontend dockerfile.v0: failed to build LLB:
failed to load cache key: rpc error: code = Unknown desc =
error getting credentials - err:
exec: "docker-credential-desktop.exe": executable file
not found in $PATH, out: ``
```

Use the thread below for troubleshooting options:
<https://forums.docker.com/t/docker-credential-desktop-exe-executable-file-not-found-in-path-using-wsl2/100225>

One workaround is to change `credsStore` to `credStore` in
`~/.docker/config.json`.
This disables desktop credential helper integration.

- If you get this shared memory error, PostgreSQL may have exceeded the
  default 1 GB shared memory limit in the container:

```text
ERROR: could not resize shared memory segment
"/PostgreSQL.1668919278" to 67129600 bytes:
No space left on device
```

Rebuild the container after adding the following to
`~/.devcontainer/devcontainer.json`:

```json
{
  "runArgs": [
    "--shm-size=5g"
  ]
}
```

- If Docker installation fails with this error:

```text
For security reasons the C:\ProgramData\DockerDesktop
must be owned by an elevated account.
```

A workaround is to delete `C:\ProgramData\DockerDesktop`,
open PowerShell as Administrator,
create the folder again with `mkdir DockerDesktop`, and retry.
See this thread for details:
<https://forums.docker.com/t/couldnt-install-docker-in-my-windows-laptop-it-says-the-c-programdata-must-be-owned-by-elevated-account/151542>
