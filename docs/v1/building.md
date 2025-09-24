# Building and Running DocumentDB from Source

If you want to build and run DocumentDB from source (instead of using Docker), follow these steps. This guide is designed for beginners and works best on Ubuntu/Debian. For other operating systems, package names may differ.

### Prerequisites

Install the required dependencies:

```bash
sudo apt update
sudo apt install build-essential libbson-dev postgresql-server-dev-all pkg-config rustc cargo
```

### Step 1: Build PostgreSQL Extensions

```bash
cd /path/to/documentdb/pg_documentdb_core
make
sudo make install

cd /path/to/documentdb/pg_documentdb
make
sudo make install
```

### Step 2: Build the Gateway

```bash
cd /path/to/documentdb/pg_documentdb_gw
cargo build --profile=release-with-symbols
```

### Step 3: Start PostgreSQL

If PostgreSQL isn’t running, start it:

```bash
sudo service postgresql start
```

### Step 4: Enable Extensions

Connect to PostgreSQL and run:

```bash
psql -U postgres -d postgres -c "CREATE EXTENSION pg_documentdb_core;"
psql -U postgres -d postgres -c "CREATE EXTENSION pg_documentdb;"
```

### Step 5: Start the Gateway

Use the provided script:

```bash
cd /path/to/documentdb/scripts
./build_and_start_gateway.sh -u <username> -p <password>
```
Replace `<username>` and `<password>` with your desired credentials.

### Step 6: Connect and Test

Use a MongoDB client (like `mongosh`):

```bash
mongosh --host localhost --port 10260
```

Try basic MongoDB commands to verify everything works.

### Troubleshooting

- **libbson-static-1.0 not found:**  Install `libbson-dev` and check your `PKG_CONFIG_PATH`.
- **pg_config not found:**  Install `postgresql-server-dev-all`.
- **Other errors:**  Double-check all dependencies and your OS version.

### Need Help?

- Join our [Discord](https://discord.gg/vH7bYu524D)
- See [docs](https://documentdb.io/docs) for more details