# Quickstart: DocumentDB with Docker Compose

The smallest useful Compose setup: one DocumentDB service with persistent
storage, a health check, and the port published to the host.

## Run it

```bash
docker compose up --wait
```

`--wait` blocks until the container reports **healthy**, so when the command
returns you can connect immediately:

```bash
mongosh "mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
```

Or from Python:

```python
import pymongo
client = pymongo.MongoClient(
    "mongodb://demo:DemoPass100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
)
client.quickstart.greetings.insert_one({"message": "hello documentdb"})
```

## Change the credentials

Either edit `compose.yaml`, or override per invocation without editing:

```bash
DOCUMENTDB_USERNAME=myuser DOCUMENTDB_PASSWORD='my-secret' docker compose up --wait
```

The credentials are fixed on first boot (they provision the gateway user), so
changing them later requires a fresh data volume (`docker compose down -v`).

## Tear down

```bash
docker compose down        # keeps the data volume
docker compose down -v     # deletes the data volume too
```

## Where this example goes next

- An application container that waits for DocumentDB: [`../compose-app`](../compose-app)
- Seeding the database on first boot: [`../compose-init-data`](../compose-init-data)
- Running your dev environment itself in a container: [`../devcontainer`](../devcontainer)
- Shared concepts (healthcheck, TLS, ports, persistence): [`../README.md`](../README.md)
