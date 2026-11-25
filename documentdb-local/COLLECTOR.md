# Local gateway metrics

The optional collector image packages OpenTelemetry Collector Contrib alongside the database. It does not change the published base image. From the repository root:

```sh
docker build -f documentdb-local/Dockerfile.collector -t documentdb-local:collector .
bash documentdb-local/scripts/documentdb_local_tests/test_collector_image.sh documentdb-local:collector
```

Start it with the usual database options plus `--enable-telemetry true` (or `ENABLE_TELEMETRY=true`). The gateway sends operational metrics over OTLP/gRPC to `127.0.0.1:14317`. To scrape them, run `docker exec <container> curl -fsS http://127.0.0.1:9464/metrics`. Both listeners are inside the container; no port publishing is required. Allow one gateway export interval after issuing a request.

The collector stays off by default. An explicit gateway metrics or shared OTLP endpoint selects your own receiver instead. The gateway's `TelemetryOptions.Metrics` settings retain precedence over environment settings. Setting `OTEL_METRICS_ENABLED=false` disables metrics unless the gateway configuration explicitly enables them. No trace or log pipeline is installed. A collector failure does not stop the database; restart the container to restart collection.

The built-in exporter serves metrics locally, not to Application Insights or any public endpoint. Operational labels may include database and collection names. Treat scrapes as diagnostic data, especially if forwarding them yourself. Anonymous usage reporting is separate: pass `--disable-usage-telemetry` to disable it. See [the privacy statement](PRIVACY.md).

### Why a separate image?

The [release gateway build](../.github/workflows/build_gateway.yml) passes only the PostgreSQL extension package to the [release Dockerfile](../packaging/gateway/docker/Dockerfile_documentdb_local). It builds the gateway from source, so the gateway package's post-install script and the native host installer do not run. The local SQL-stub installer does run during the template bake, but also at database startup and during native setup; it is not an image dependency hook. Using it to fetch the collector would couple database initialization to software installation. To include the collector in a normal release, add the pinned collector stage and its binary/config copies to the release Dockerfile instead. No runtime download is needed.

[RFC 0014](https://github.com/documentdb/documentdb/pull/493) was closed without merging. This image uses its managed-child and bounded-shutdown approach, not its proposed default-on Application Insights, log collection or lifecycle events. The local metrics endpoint is not a scrubbed analytics feed.