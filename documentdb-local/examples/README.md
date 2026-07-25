# DocumentDB local — Docker Compose & dev container examples

Ready-to-run examples for using the
[`documentdb-local`](https://github.com/documentdb/documentdb/pkgs/container/documentdb%2Fdocumentdb-local)
image with Docker Compose. Each directory is self-contained: `cd` in and run
the command from its README.

| Example | What it shows |
|---|---|
| [`compose-quickstart`](./compose-quickstart) | The smallest useful setup: one service, persistent volume, healthcheck, host port. |
| [`compose-app`](./compose-app) | An app container gated on `service_healthy` — ordered startup without retry loops, and the CI `--exit-code-from` pattern. |
| [`compose-init-data`](./compose-init-data) | Seeding the database on first boot from mounted `.js` scripts. |
| [`devcontainer`](./devcontainer) | A full containerized dev environment with DocumentDB as a sidecar — nothing installed on the host. |

The concepts below are shared by all of them.

## Healthcheck

"The container is running" does not mean "the database is ready": on first
boot the entrypoint initializes PostgreSQL, provisions the user, starts the
gateway, and runs any data seeding — which can take minutes on slow Docker
Desktop filesystems. The examples therefore probe for both of:

1. the entrypoint's readiness line (`=== DocumentDB is ready ===`) in
   `/var/log/documentdb/gateway_entrypoint.log`, which is printed only after
   startup *including data initialization* has finished, and
2. the gateway accepting TCP connections on its port.

```yaml
healthcheck:
  test: ["CMD-SHELL", "grep -qF '=== DocumentDB is ready ===' /var/log/documentdb/gateway_entrypoint.log && nc -z localhost 10260"]
  interval: 10s
  timeout: 5s
  retries: 3
  start_period: 300s
```

With that in place, `docker compose up --wait` blocks until ready, and other
services can gate on it:

```yaml
depends_on:
  documentdb:
    condition: service_healthy
```

Images built after issue #482 ship this logic **built in** (as
`/home/documentdb/gateway/scripts/documentdb_healthcheck.sh`, wired up as the
image's `HEALTHCHECK`), so on current images the explicit block is optional —
keep it only if you pin an older image, need custom timings, or run on an
engine where you want a shorter steady-state interval. On Docker Engine 25+
you can add `start_interval: 2s` to make the first healthy report faster.

## Credentials

`USERNAME` / `PASSWORD` environment variables provision the gateway user on
first boot. The examples use throwaway local-development credentials
(`demo` / `DemoPass100`); change them in the compose file or override via
environment variables where the example supports it. Credentials are fixed
per data volume — to change them later, start fresh with
`docker compose down -v`.

## Connection strings

- From the **host** (with a `ports:` mapping):
  `mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true`
- From **another compose service**: replace `localhost` with the service
  name, e.g. `@documentdb:10260`. No `ports:` mapping is needed for
  service-to-service traffic.
- **Nothing installed on the host?** The image ships `mongosh`; run it
  inside the container:
  `docker compose exec documentdb mongosh "mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"`

The gateway serves TLS with a self-signed certificate by default, hence
`tls=true&tlsAllowInvalidCertificates=true`. To bring your own certificate,
mount it and set `CERT_PATH` / `KEY_FILE`; to reject non-TLS connections,
set `TLS_MODE: requireTLS`.

## Persistence

All examples mount a named volume at `/data`. Data (and the one-shot seeding
markers) live there:

- `docker compose down` / restarts keep the data;
- `docker compose down -v` deletes it — the next `up` re-initializes and
  re-seeds from scratch.

## Ports

The gateway listens on **10260** by default (chosen to avoid colliding with
a local MongoDB on 27017). To use a different host port, change only the
left side of the mapping, e.g. `"27017:10260"`. Only one running example can
map host port 10260 at a time — tear one down before starting another, or
drop the `ports:` mapping where you don't need host access.

## Troubleshooting

```bash
docker compose ps                                  # shows health status
docker inspect --format '{{json .State.Health}}' <container> | jq  # probe log
docker compose logs documentdb                     # full startup output
```

Common causes of an `unhealthy` service: a seed script in
`/init_doc_db.d` failed (see the logs; fix and `down -v`), or a very slow
first boot exceeded `start_period` (raise it).
