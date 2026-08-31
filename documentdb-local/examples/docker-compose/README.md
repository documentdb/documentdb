# Running DocumentDB Local with Docker Compose

A ready-to-use `docker compose` setup for the
[`documentdb-local`](https://github.com/documentdb/documentdb) image, with a
container health check, persistent storage, and readiness gating for dependent
services.

## Quick start

You need `docker` and [`mongosh`](https://www.mongodb.com/docs/mongodb-shell/)
on the host; the credential one-liner below also uses `openssl` (any random
generator works in its place).

```bash
cd documentdb-local/examples/docker-compose

# 1. Generate credentials for this run. They live only in your shell
#    environment -- nothing is written to disk, and you get a fresh secret
#    every time rather than reusing one committed to a file.
export DOCUMENTDB_USERNAME=appuser
export DOCUMENTDB_PASSWORD="$(openssl rand -base64 24)"

# 2. Start DocumentDB from a freshly pulled image. The pull matters: plain
#    `up` keeps whatever :latest you already have, and an image from before
#    the health probe shipped reports no health at all (see below).
docker compose pull
docker compose up -d

# 3. Wait for it to report healthy
docker compose ps
# NAME                        ...   STATUS
# docker-compose-documentdb-1 ...   Up 45 seconds (healthy)

# 4. Connect (from the host), using the credentials generated in step 1
mongosh "mongodb://localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" \
    --username "$DOCUMENTDB_USERNAME" --password "$DOCUMENTDB_PASSWORD"
```

On Windows, run the same steps from PowerShell with:

```powershell
$bytes = [byte[]]::new(24)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$env:DOCUMENTDB_USERNAME = 'appuser'
$env:DOCUMENTDB_PASSWORD = [Convert]::ToBase64String($bytes)
docker compose pull
docker compose up -d
```

`docker compose` reads both variables from your environment and aborts with a
clear error before creating anything if either is unset, so an unconfigured
stack cannot silently come up on the image's well-known default credentials.
The check applies to *every* compose command, including `down` — so to tear
down the stack from a shell where the variables are no longer set, pass
placeholders (they are not used for anything):

```bash
DOCUMENTDB_USERNAME=x DOCUMENTDB_PASSWORD=x docker compose down -v
```

Pick any username that does not start with a reserved role prefix —
`documentdb`, `citus`, `pg` or `internal_role`, matched case-insensitively.
The gateway would refuse such a name at authentication time, so the container
rejects it at startup rather than coming up with a login that can never work.

Because the password is generated per run, treat the stack as disposable: to
rotate credentials, tear it down (`docker compose down -v`, which also clears
the data volume — use the placeholder form above if the variables are gone)
and repeat step 1. Restarting an existing stack with a new password will not
change the already-provisioned user — that user is created once, on a fresh
data volume.

## The health check

The image ships a built-in health probe at
`/usr/local/bin/documentdb-healthcheck` (source:
[`documentdb-local/scripts/healthcheck.sh`](../../scripts/healthcheck.sh)),
so this compose file needs no `healthcheck:` block. The probe reports
healthy only when all of the following hold:

> **Image requirement:** the probe ships with the image, so `:latest` reports
> health only from the first release that contains it. On an older image the
> container has no health state, and anything gated on `service_healthy` —
> including the `wait-for-healthy` service below — cannot start. The
> `docker compose pull` in step 2 exists for exactly this reason: plain `up`
> does not re-pull an image you already have.

1. **Startup completed** — the entrypoint publishes its resolved runtime
   settings to `/tmp/documentdb-local-runtime.env` only after initialization
   (including sample/custom data seeding) finishes. Services gated on
   `depends_on: condition: service_healthy` therefore never start against a
   database that is still initializing. (One deliberate exception: after a
   *failed* custom seed, a restarted container comes up — and reports
   healthy — without re-running the scripts; see "Seeding data".)
2. **PostgreSQL accepts connections** on `localhost`, where the gateway in
   this image always dials it. This is probed whether PostgreSQL runs inside
   this container (the default) or is started externally and shared into its
   network namespace — a TLS handshake alone cannot see a dead backend.
3. **The gateway completes a TLS handshake** on the DocumentDB port. The
   gateway serves TLS in every `tlsMode`, so the probe is valid in all modes.

Because the probe reads the entrypoint's published state, it automatically
tracks a non-default port whether you set it via the `DOCUMENTDB_PORT`
environment variable or the `--documentdb-port` CLI flag.

Default timings (override with a `healthcheck:` block if needed):
`interval=30s`, `timeout=10s`, `retries=3`, `start_period=600s`. The start
period absorbs a slow first boot — initdb on a cold volume, plus the
entrypoint's own up-to-600s wait for PostgreSQL: failing probes during it do
not count toward `retries`, so a normally slow boot is not flagged while
`depends_on: condition: service_healthy` waits. (During that startup wait, a
dependency that does turn unhealthy aborts the dependent's startup; Compose
does not monitor health after the dependent is running.) The start period is
a budget, not a guarantee — a boot that takes even longer can outrun it, for
example very large custom seed scripts or a `DOCUMENTDB_PG_READY_TIMEOUT`
raised past 600s (the baked-in start period cannot track that variable), so
give such workloads a larger `start_period` via the override block. A fast boot is not delayed: a probe
that succeeds during the start period marks the container healthy without
waiting the period out.

To inspect health status and the probe's last output (drop the `| jq` if you
don't have it installed):

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

Like every compose command here, this needs the two credential variables set
in the shell — use the placeholder form from the quick start if they are
gone.

## Seeding data

- **Built-in sample data:** add `INIT_DATA: "true"` to the `environment:`
  block to load the sample `sampledb` database on first boot.
- **Your own scripts:** uncomment the `./init-data:/init_doc_db.d:ro` volume
  in `docker-compose.yml` and put `.js` files (run with mongosh, in
  alphabetical order) in `./init-data/`.

Each seeding path runs on the first boot of a fresh data volume and is
skipped on later boots once it succeeded. On failure the container exits,
and the two paths then differ: a failed **custom** seed is *not* retried on
restart — the scripts may have partially applied and are not assumed
idempotent, so the container comes back up (and reports healthy) without
them; a failed **sample-data** seed is retried on every boot until it
succeeds. Either way, recreate the volume (`down -v`) to re-seed from
scratch.

## Changing the port

To publish a different host port, change only the host side of the mapping
(e.g. `"127.0.0.1:27017:10260"`). To change the port inside the container,
set `DOCUMENTDB_PORT` in the `environment:` block and make the container
side of the mapping match it — the health check picks up the new port
automatically.

The mapping binds to `127.0.0.1` on purpose: Docker's port publishing
bypasses host firewalls such as `ufw`/`firewalld`, so an unprefixed mapping
would expose the emulator to your local network. Remove the `127.0.0.1:`
prefix only if that is what you want.
