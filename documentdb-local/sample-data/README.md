# Sample Data for DocumentDB

This directory contains the built-in `StoreData` sample dataset used by
DocumentDB local containers and native packages.

## Collections

The loader creates the following collections in the `StoreData` database:

- `stores`: 41,505 retail store documents with varied schemas covering
  locations, staffing, sales, inventory, promotions, operating hours, dates,
  timestamps, and binary values.
- `ratings`: 2 store rating documents whose `_id` values correspond to stores
  in the main collection.

The source exports are stored as deterministic gzip-compressed Extended JSON:

- `StoreData.stores.json.gz`
- `StoreData.ratings.json.gz`

To regenerate the checked-in artifacts from equivalent uncompressed exports:

```bash
jq -c . StoreData.stores.json | gzip -n -9 > StoreData.stores.json.gz
jq -c . StoreData.ratings.json | gzip -n -9 > StoreData.ratings.json.gz
```

`01-store-data.js` decompresses and parses the files with mongosh's built-in
Node.js and `EJSON` support. It inserts documents in bounded batches and ignores
only duplicate-key errors, so direct re-runs repair missing documents without
duplicating existing ones.

## Usage

Built-in sample data is loaded only when explicitly enabled with
`--init-data true` or `INIT_DATA=true`. Container seeding runs once per data
volume and is skipped on later restarts. To seed again, start with a fresh data
volume.

Packaged installs also keep sample data optional:

```bash
sudo documentdb-setup --load-sample-data
```

This option requires `mongosh` on the host.

To run the loader manually, keep the loader and compressed files together:

```bash
cd /path/to/sample-data
DOCUMENTDB_INIT_FILE="$PWD/01-store-data.js" \
mongosh localhost:10260 \
  -u username \
  -p '<password>' \
  --authenticationMechanism SCRAM-SHA-256 \
  --tls \
  --tlsAllowInvalidCertificates \
  --file 01-store-data.js
```
