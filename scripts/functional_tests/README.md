# Local functional tests

This directory contains the local Docker Compose flow for running DocumentDB functional tests outside GitHub Actions. The CI workflow also reuses `run_with_compose.sh`, so local runs and workflow runs follow the same path.

## Prerequisites

- Docker with the Compose plugin (`docker compose`)
- A functional test image to run, provided either as a registry reference or a local image ID
- A Bash-capable shell. On Windows, use WSL or another environment that can run the Bash helper scripts in this directory.

## Quick start

Run the smoke suite:

```bash
./scripts/functional_tests/run_with_compose.sh run
```

Run the full suite:

```bash
./scripts/functional_tests/run_with_compose.sh run --scope full
```

Run the full suite while excluding `deselect.list`:

```bash
./scripts/functional_tests/run_with_compose.sh run --scope full --exclude-deselect-file
```

Run a single test or subset:

```bash
./scripts/functional_tests/run_with_compose.sh run --scope full --pytest-args "-k test_find_basic_queries"
```

`--test-image` accepts any Docker image reference or a local image ID. If you omit it, local
runs fall back to `ghcr.io/documentdb/functional-tests:latest`. In GitHub Actions, the workflow
resolves the pinned digest from `test-image-pin.txt` so PR validation is stable across test-image
updates.

`--pytest-args` is passed directly to pytest inside the functional test container.

## Outputs

- Test results are written to `functional-test-results/` in the repository root.
- The local stack is defined in `docker-compose.yml`.
- Temporary deselections live in `deselect.list`.

## Useful commands

Show stack logs:

```bash
./scripts/functional_tests/run_with_compose.sh logs
```

Tear down the local stack:

```bash
./scripts/functional_tests/run_with_compose.sh down
```

Build the local `documentdb-local` image without running tests:

```bash
./scripts/functional_tests/run_with_compose.sh build
```

Run tests again without rebuilding the local image:

```bash
./scripts/functional_tests/run_with_compose.sh test \
  --test-image ghcr.io/documentdb/functional-tests:latest
```

## Troubleshooting: test image updated

The functional test runner image is external and mutable. Local runs use `:latest` by default,
but CI pins an immutable digest in `test-image-pin.txt`.

If local results no longer match CI:

1. Reproduce the CI image locally:

   ```bash
   pinned_image="$(bash ./scripts/functional_tests/read_pin.sh)"
   ./scripts/functional_tests/run_with_compose.sh run --scope full --test-image "${pinned_image}"
   ```

2. If `:latest` fails but the pinned image passes, the upstream test image changed and CI is still
   protected by the pin.
3. Update the pin and `deselect.list` together through the weekly `update_test_image.yml` workflow
   instead of changing only one of them by hand.

## Image pinning

CI pins the test image by immutable `@sha256:` digest in `test-image-pin.txt`. The weekly
`update_test_image.yml` workflow resolves the latest image, runs the full test suite, updates
the deselect list, and opens a PR with both changes.

**Retention:** Pinned digests must remain available in the container registry for the lifetime
of any open PR that references them. Avoid pruning GHCR package versions that are still
referenced by `test-image-pin.txt` on any active branch.
