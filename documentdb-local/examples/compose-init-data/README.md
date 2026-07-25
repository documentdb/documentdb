# Seeding DocumentDB on first boot

Mounts a directory of mongosh `.js` scripts into the container's
`/init_doc_db.d`; the entrypoint executes them in alphabetical order the
first time the data volume is used. This example seeds a `library` database
with a `books` collection and two indexes.

## Run it

```bash
docker compose up --wait
```

Verify the seed landed:

```bash
mongosh "mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" \
    --eval "db.getSiblingDB('library').books.countDocuments()"
# 3
```

## Semantics worth knowing

- **Once per fresh data volume.** Scripts run only when the data volume has
  not been initialized before. Restarts and `docker compose down && up`
  against the same volume skip them. To re-seed from scratch:
  `docker compose down -v && docker compose up --wait`.
- **A failed seed stops the container** and is *not* retried on the next
  boot against the same volume (re-running a partially applied,
  non-idempotent script could corrupt data). Fix the script, then start
  with a fresh volume.
- **Ordering is alphabetical.** Number the files (`01-...`, `02-...`) to make
  it explicit. Write scripts in mongosh syntax; `use('dbname')` switches
  databases.
- **`service_healthy` waits for the seed.** The healthcheck passes only after
  initialization completes, so `docker compose up --wait` (and any dependent
  service) never observes the database pre-seed.
- **Built-in sample data** is separate and opt-in: set `INIT_DATA: "true"`
  on the service to also load the image's bundled `sampledb` dataset
  ([`documentdb-local/sample-data`](../../sample-data)).

## Tear down

```bash
docker compose down -v
```
