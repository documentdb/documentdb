# Dev container + DocumentDB sidecar

Develop and test against DocumentDB **without installing anything on your
machine** — no Python, no mongosh, no database. The dev environment itself is
a container ([Dev Containers](https://containers.dev/)), and DocumentDB runs
next to it as a Compose sidecar.

```
.devcontainer/
  devcontainer.json   <- tells VS Code / Codespaces how to attach
  compose.yaml        <- dev environment + documentdb services
tests/
  test_documentdb.py  <- example tests that talk to the sidecar
requirements-dev.txt
```

## Use it

Open this folder in VS Code and run **Dev Containers: Reopen in Container**
(or create a GitHub Codespace on it). VS Code brings up both services, waits
for DocumentDB to be healthy, attaches to the `dev` service, and installs the
Python dependencies. Then, in the integrated terminal:

```bash
pytest
```

The tests read `DOCUMENTDB_URI` from the environment (set in
`compose.yaml`) and talk to the sidecar over the Compose network.

You can also drive it without an editor, using the
[devcontainer CLI](https://github.com/devcontainers/cli):

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . pytest
```

## How the pieces fit

- `devcontainer.json` points at the compose file (`dockerComposeFile`), names
  the service to attach to (`service: dev`), and forwards the sidecar's port
  to the host (`"documentdb:10260"`) so host-side tools can connect too.
- The `dev` service runs `sleep infinity` — a dev container has no app
  process; the editor attaches to it and your shell/tests run inside.
- `depends_on: condition: service_healthy` means the sidecar is ready before
  the dev container starts: tests never need connection-retry loops.
- Inside the dev container, DocumentDB is at `documentdb:10260` (the service
  name), **not** `localhost`.

## Adapting it to your project

Copy the `.devcontainer/` directory into your repository root and adjust:
the `dev` service image (any language stack works), the workspace mount, and
`postCreateCommand`. Everything DocumentDB-specific — image, credentials,
healthcheck, volume — stays as-is.
