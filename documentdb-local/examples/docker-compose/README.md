# Running DocumentDB Local with Docker Compose

A ready-to-use `docker compose` setup for the
[`documentdb-local`](https://github.com/documentdb/documentdb) image, with a
container health check, persistent storage, and an optional smoke test.

## Quick start

```bash
cd documentdb-local/examples/docker-compose

# 1. Set your credentials
cp .env.example .env
$EDITOR .env

# 2. Start DocumentDB
docker compose up -d

# 3. Wait for it to report healthy
docker compose ps
# NAME                        ...   STATUS
# docker-compose-documentdb-1 ...   Up 45 seconds (healthy)

# 4. Connect (from the host)
mongosh "mongodb://localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" \
    --username <your-username> --password <your-password>
```

Or run the bundled one-shot connectivity check, which waits for the health
check before connecting:

```bash
docker compose run --rm smoke-test
```

## The health check

The image ships a built-in health probe at
`/usr/local/bin/documentdb-healthcheck` (source:
[`documentdb-local/scripts/healthcheck.sh`](../../scripts/healthcheck.sh)),
so this compose file needs no `healthcheck:` block. The probe reports
healthy only when all of the following hold:

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
`interval=30s`, `timeout=10s`, `retries=3`, `start_period=120s`. The start
period covers first-boot database initialization on slow machines; failing
probes during it do not count toward `retries`.

To inspect health status and the probe's last output:

```bash
docker inspect --format '{{json .State.Health}}' <container> | jq
```

## Waiting for DocumentDB in your own services

Add a `depends_on` condition to any service that needs the database (see the
`smoke-test` service in [`docker-compose.yml`](docker-compose.yml) for a full
example):

```yaml
services:
  my-app:
    depends_on:
      documentdb:
        condition: service_healthy
```

Inside the compose network, connect to `documentdb:10260` (the service
name), with `tls=true&tlsAllowInvalidCertificates=true` — the emulator's
auto-generated certificate is self-signed.

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
