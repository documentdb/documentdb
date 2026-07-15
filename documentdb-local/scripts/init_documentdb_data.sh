#!/bin/bash

# DocumentDB Data Initialization Script
# This script initializes DocumentDB with data from JavaScript files

set -e
set -u

# Default values
USERNAME="default_user"
PASSWORD=""
INIT_DATA_PATH="/init_doc_db.d"
VERBOSE="false"
DOCUMENTDB_PORT="10260"
# When set (custom user-provided initialization only), this marker is written immediately
# before the first user script runs, so a non-idempotent init that fails partway is not
# re-run on a restart and cannot loop. Empty for built-in sample data, which is idempotent.
ATTEMPT_MARKER=""
LOG_FILE="${ENTRYPOINT_LOG:-/var/log/documentdb/gateway_entrypoint.log}"
LOG_FILE_AVAILABLE="false"

if [ -n "$LOG_FILE" ]; then
    if touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE_AVAILABLE="true"
    else
        echo "Warning: Unable to append to log file: $LOG_FILE"
    fi
fi

# Print usage information
usage() {
    cat << EOF
DocumentDB Data Initialization Script

Usage: $0 [OPTIONS]

Options:
  -h, --help                    Show this help message
  -H, --host HOST              DocumentDB host (default: localhost)
  -P, --port PORT              DocumentDB port (default: 10260)
  -u, --username USERNAME      DocumentDB username (default: default_user)
  -p, --password PASSWORD      DocumentDB password (required)
  -d, --data-path PATH         Path to directory containing .js initialization files
                               (default: /init_doc_db.d)
  -v, --verbose                Enable verbose output
  --attempt-marker PATH        Internal: marker file recorded immediately before the first
                               user script runs, making custom initialization one-shot per
                               data volume. If it cannot be written, initialization is aborted
                               before any data is touched. Omit for idempotent built-in data.

Examples:
  # Initialize with custom data files
  $0 -p mypassword -d /path/to/init/scripts

  # Initialize with specific host and port
  $0 -H myhost -P 27017 -u myuser -p mypassword -d /custom/path

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -H|--host)
            DOCUMENTDB_HOST="$2"
            shift 2
            ;;
        -P|--port)
            DOCUMENTDB_PORT="$2"
            shift 2
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -d|--data-path)
            INIT_DATA_PATH="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        --attempt-marker)
            ATTEMPT_MARKER="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$PASSWORD" ]; then
    echo "Error: Password is required. Use -p or --password to specify the password."
    exit 1
fi

# Verbose logging function
log() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

print_and_log() {
    local message="$1"
    echo "$message"
    if [ "$LOG_FILE_AVAILABLE" = "true" ]; then
        printf '%s\n' "$message" >> "$LOG_FILE"
    fi
}

print_file_and_log() {
    local file_path="$1"
    if [ "$LOG_FILE_AVAILABLE" = "true" ]; then
        tee -a "$LOG_FILE" < "$file_path"
    else
        cat "$file_path"
    fi
}

# Record the one-shot custom-init marker right before the first user script mutates data.
# This must happen BEFORE any data is written: user scripts may be non-idempotent, so if the
# marker cannot be persisted we refuse to run rather than mutate-then-fail-to-mark, which
# would let a restart re-run the partially-applied scripts and loop forever (#612).
# If the marker truly cannot be persisted we fail loudly on every boot (no data is mutated,
# so there is no corruption); a writable data directory is a hard requirement, not optional.
write_attempt_marker_or_abort() {
    local marker="$1"
    if ! mkdir -p "$(dirname "$marker")" 2>/dev/null || ! touch "$marker" 2>/dev/null; then
        echo "Error: could not write initialization marker $marker."
        echo "Refusing to run custom initialization without it to avoid a restart loop."
        echo "Ensure the data directory is writable, then start with a fresh data volume."
        return 1
    fi
    return 0
}

# Function to wait for DocumentDB to be ready
wait_for_documentdb() {
    local max_attempts=30
    local attempt=1
    
    echo "Waiting for DocumentDB to be ready at localhost:${DOCUMENTDB_PORT}..."
    
    while [ $attempt -le $max_attempts ]; do
        if command -v mongosh >/dev/null 2>&1; then
            if mongosh "localhost:${DOCUMENTDB_PORT}" -u "$USERNAME" -p "$PASSWORD" --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
                echo "DocumentDB is ready!"
                return 0
            fi
        else
            echo "Warning: mongosh not found. Cannot verify DocumentDB readiness."
            return 1
        fi
        
        log "Attempt $attempt/$max_attempts failed, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "Error: DocumentDB did not become ready within $(($max_attempts * 2)) seconds"
    return 1
}

# Function to execute initialization scripts from a directory
run_init_scripts() {
    local init_dir="$1"
    local script_count=0
    local attempt_marked="false"
    
    if [ ! -d "$init_dir" ]; then
        echo "Error: Initialization directory not found: $init_dir"
        return 1
    fi
    
    echo "Processing initialization scripts from: $init_dir"
    
    # Check if mongosh is available
    if ! command -v mongosh >/dev/null 2>&1; then
        echo "Error: mongosh not found. Please install mongosh to run initialization scripts."
        return 1
    fi
    
    # Process .js files in alphabetical order
    for init_file in "$init_dir"/*.js; do
        if [ -f "$init_file" ]; then
            script_count=$((script_count + 1))

            # Mark the volume as initialized once, just before the first user script runs
            # (after all readiness/preflight checks), so a failed custom init is not retried
            # on restart. Aborting here leaves the data untouched, so a retry stays safe (#612).
            if [ -n "$ATTEMPT_MARKER" ] && [ "$attempt_marked" = "false" ]; then
                if ! write_attempt_marker_or_abort "$ATTEMPT_MARKER"; then
                    return 1
                fi
                attempt_marked="true"
            fi

            echo "Executing initialization script: $(basename "$init_file")"
            log "Full path: $init_file"
            print_and_log "---- Begin init data: $(basename \"$init_file\") ----"
            print_file_and_log "$init_file"
            print_and_log "---- End init data: $(basename \"$init_file\") ----"

            if mongosh "localhost:${DOCUMENTDB_PORT}" -u "$USERNAME" -p "$PASSWORD" --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --file "$init_file"; then
                log "Successfully executed: $(basename "$init_file")"
            else
                echo "Error: Failed to execute: $(basename "$init_file")"
                echo "This indicates invalid JavaScript syntax or operation error."
                return 1
            fi
        fi
    done
    
    if [ $script_count -eq 0 ]; then
        echo "No JavaScript files found in: $init_dir"
        return 1
    fi
    
    echo "Processed $script_count initialization script(s)"
    
    # Log completion message that the test script can monitor
    echo "Sample data initialization completed!"
    return 0
}

# Main initialization logic
main() {
    echo "Starting DocumentDB data initialization..."
    echo "Host: localhost:${DOCUMENTDB_PORT}"
    echo "Username: $USERNAME"
    
    # Wait for DocumentDB to be ready
    if ! wait_for_documentdb; then
        exit 1
    fi
    
    # Use custom initialization data
    echo "Using custom initialization data from: $INIT_DATA_PATH"
    if ! run_init_scripts "$INIT_DATA_PATH"; then
        echo "Error: Failed to process custom initialization data"
        exit 1
    fi
    
    echo "Database initialization completed successfully!"
}

# Run the main function
main
