# App + DocumentDB: ordered startup with `service_healthy`

A two-service setup: DocumentDB plus a small Python app that connects,
inserts a document, reads it back, and exits. The app container is held back
by `depends_on: condition: service_healthy` until DocumentDB is actually
ready — no retry loop, no sleep, no hand-rolled wait-for-it script.

## Run it

```bash
docker compose up --build --exit-code-from app
```

Expected output ends with:

```
app-1  | Round-trip succeeded: 'hello from docker compose'
app-1 exited with code 0
```

`--exit-code-from app` makes the compose invocation exit with the app's exit
code, which is exactly what a CI job wants: green when the app's round trip
succeeded, red otherwise.

## The two things this example demonstrates

1. **Startup ordering.** `depends_on` with `condition: service_healthy`
   defers the app until DocumentDB's healthcheck passes. The healthcheck only
   reports healthy after the entrypoint finished startup — including any
   first-boot data initialization — so the app never observes a half-started
   database.

2. **Service-to-service networking.** The app's connection string uses the
   *service name* as the host: `mongodb://...@documentdb:10260/...`. On the
   Compose network, `localhost` inside the app container is the app itself —
   a classic first-compose-file stumble. Note the documentdb service publishes
   no ports at all; host port mapping is only needed for clients running on
   the host.

## Tear down

```bash
docker compose down -v
```
