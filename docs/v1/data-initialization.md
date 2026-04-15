# Data Initialization Support

DocumentDB supports two initialization modes when the emulator container starts:

* Built-in sample data for quick exploration (disabled by default, opt-in)
* Custom JavaScript initialization scripts supplied by the user

## Environment Variables

The entrypoint honors the following environment variables:

- `INIT_DATA`: Set to `true` to load built-in sample data (default: `false`).
- `INIT_DATA_PATH`: Directory containing `.js` initialization files (default: `/init_doc_db.d`).
- `SKIP_INIT_DATA`: Legacy alias for disabling built-in sample data.

> Note: Custom initialization via `--init-data-path` is independent of `INIT_DATA`; custom scripts run whenever the directory exists and contains `.js` files.

## Command Line Options

- `--init-data [true|false]`: Enable or disable loading the built-in sample collections.
- `--init-data-path [PATH]`: Execute all `.js` files in the specified directory (alphabetical order) using `mongosh`.
- `--skip-init-data`: Legacy alias for `--init-data false`.

If no option is supplied, the emulator starts without built-in sample data.

## Usage Examples

### Default startup (no initialization data)
```bash
docker run -p 10260:10260 -p 9712:9712 \
  --password mypassword \
  documentdb/local
```

### Start with built-in sample data
```bash
docker run -p 10260:10260 -p 9712:9712 \
  --init-data true \
  --password mypassword \
  documentdb/local
```

### Use custom initialization scripts
```bash
docker run -p 10260:10260 -p 9712:9712 \
  -v /path/to/your/init/scripts:/init_doc_db.d \
  --init-data-path /init_doc_db.d \
  --password mypassword \
  documentdb/local
```

### Configure via environment variables
```bash
docker run -p 10260:10260 -p 9712:9712 \
  -e INIT_DATA_PATH=/custom/init/path \
  -e INIT_DATA=false \
  -e PASSWORD=mypassword \
  -v /path/to/your/init/scripts:/custom/init/path \
  documentdb/local
```

## Built-in Sample Data

When `--init-data true` (or `INIT_DATA=true`) is supplied, the following collections are created in the `sampledb` database:
- users (5 sample users)
- products (5 sample products)
- orders (4 sample orders)
- analytics (sample metrics and activity data)

## Security Note

Built-in sample data is intended for evaluation scenarios. Keep it disabled by default for production-style startup paths, and enable it only with `--init-data true` / `INIT_DATA=true` when you want the demo dataset.
