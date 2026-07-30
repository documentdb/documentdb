# Running DocumentDB Local with Docker Compose

A ready-to-use `docker compose` setup for the
[`documentdb-local`](https://github.com/documentdb/documentdb) image, with a
container health check, persistent storage, and readiness gating for dependent
services.

## Quick start

```bash
cd documentdb-local/examples/docker-compose

# 1. Generate credentials for this run. They live only in your shell
#    environment -- nothing is written to disk, and you get a fresh secret
#    every time rather than reusing one committed to a file.
export DOCUMENTDB_USERNAME=appuser
export DOCUMENTDB_PASSWORD="$(openssl rand -base64 24)"

# 2. Start DocumentDB
docker compose up -d

# 3. Wait for it to report healthy
docker compose ps
# NAME                        ...   STATUS
# docker-compose-documentdb-1 ...   Up 45 seconds (healthy)

# 4. Connect (from the host), using the credentials generated in step 1
mongosh "mongodb://localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" \
    --username <your-username> --password <your-password>
```

`docker compose` reads both variables from your environment; it refuses to
start with a clear error if either is unset, so an unconfigured stack cannot
silently come up on the image's well-known default credentials.

Pick any username that does not start with a reserved role prefix —
`documentdb`, `citus`, `pg` or `internal_role`. The gateway would refuse such
a name at authentication time, so the container rejects it at startup rather
than coming up with a login that can never work.

Because the password is generated per run, treat the stack as disposable: to
rotate credentials, tear it down (`docker compose down -v`, which also clears
the data volume) and repeat step 1. Restarting an existing stack with a new
password will not change the already-provisioned user — that user is created
once, on a fresh data volume.

## The health check

The image ships a built-in health probe at
`/usr/local/bin/documentdb-healthcheck` (source:
[`documentdb-local/scripts/healthcheck.sh`](../../scripts/healthcheck.sh)),
so this compose file needs no `healthcheck:` block. The probe reports
healthy only when all of the following hold:

> **Image requirement:** the probe ships with the image, so `:latest` reports
> health only from the first release that contains it. On an older image the
> container has no health state, and anything gated on `service_healthy` —
> including the `wait-for-healthy` service below — cannot start. Pull a fresh
> `:latest` (or build the image from this source tree) before relying on it.

1. **Startup completed** — the entrypoint publishes its resolved runtime
   settings to `/tmp/documentdb-local-runtime.env` only after initialization
   (including sample/custom data seeding) finishes. Services gated on
   `depends_on: condition: service_healthy` therefore never see a
   half-initialized database.
2. **PostgreSQL accepts connections** (when the container runs the bundled
   PostgreSQL, i.e. the default `START_POSTGRESQL=true`).
3. **The gateway completes a TLS handshake** on the DocumentDB port. The
   gateway serves TLS in every `tlsMode`, so the probe is valid in all modes.

Because the probe reads the entrypoint's published state, it automatically
tracks a non-default port whether you set it via the `DOCUMENTDB_PORT`
environment variable or the `--documentdb-port` CLI flag.

Default timings (override with a `healthcheck:` block if needed):
`interval=30s`, `timeout=10s`, `retries=3`, `start_period=600s`. The start
period matches the entrypoint's own 600s budget for PostgreSQL to come up, so
a slow first boot on a cold volume is never reported unhealthy before the
entrypoint itself gives up — which matters because `depends_on:
condition: service_healthy` aborts the dependent service as soon as the
dependency turns unhealthy. It does not delay a fast boot: failing probes
during the start period do not count toward `retries`, and the first
succeeding probe ends it.

To inspect health status and the probe's last output:

```bash
docker inspect --format '{{json .State.Health}}' <container> | jq
```

## Waiting for DocumentDB in your own services

Add a `depends_on` condition to any service that needs the database:

```yaml
services:
  my-app:
    depends_on:
      documentdb:
        condition: service_healthy
```

The `wait-for-healthy` service in [`docker-compose.yml`](docker-compose.yml)
is a runnable example of exactly that — it blocks until the health check
passes, then exits:

```bash
docker compose run --rm wait-for-healthy
```

Swap in your own image and command to turn it into your application service.

Inside the compose network, connect to `documentdb:10260` (the service
name), with `tls=true&tlsAllowInvalidCertificates=true` — the emulator's
auto-generated certificate is self-signed. Pass the credentials to your
service the same way this file does, via the environment, so they stay out of
your compose file and out of your image.

## Data persistence

Data lives in the named volume `documentdb-data`, mounted at `/data`, and
survives `docker compose down` / `up`. To start over from scratch (which
also re-runs data initialization):

```bash
docker compose down -v
```

## Seeding data

- **Built-in sample data:** add `INIT_DATA: "true"` to the `environment:`
  block to load the sample `sampledb` database on first boot.
- **Your own scripts:** uncomment the `./init-data:/init_doc_db.d:ro` volume
  in `docker-compose.yml` and put `.js` files (run with mongosh, in
  alphabetical order) in `./init-data/`.

Both run once per fresh data volume; recreate the volume (`down -v`) to
re-seed.

## Changing the port

To publish a different host port, change only the left side of the mapping
(e.g. `"27017:10260"`). To change the port inside the container as well, set
`DOCUMENTDB_PORT` in the `environment:` block and update both sides of the
mapping — the health check picks up the new port automatically.
