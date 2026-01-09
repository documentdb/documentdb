#!/bin/bash

# DocumentDB Data Initialization Script
# This script initializes DocumentDB with data from JavaScript files
#
# Design Decision: File-based Initialization Marker
# ------------------------------------------------
# This script uses a file-based marker (/var/lib/postgresql/data/.documentdb_initialized)
# instead of a database collection to track initialization status. Benefits:
# - Avoids potential collection name conflicts with user data
# - Simpler implementation without database queries for status checking
# - Follows standard container initialization patterns
# - Marker persists in the mounted data volume across container restarts
#
# The marker file contains:
# - Status: in-progress | complete
# - Timestamp: when initialization started/completed
# - Init data path: location of initialization scripts
#
# Race Condition Handling:
# - The marker file itself acts as a lock with status tracking
# - If status is "in-progress" and recent (<5 min), other processes wait
# - If status is "complete", initialization is skipped
# - On failure, marker is removed to allow retry
# - Trap handler ensures cleanup on script interruption

set -e
set -u

# Default values (INIT_DATA_PATH used for marker file naming)
DEFAULT_INIT_DATA_PATH="/init_doc_db.d"

# Cleanup function for trap
cleanup_on_exit() {
    local exit_code=$?
    # MARKER_FILE is set after INIT_DATA_PATH is parsed
    if [ -n "${MARKER_FILE:-}" ] && [ -f "$MARKER_FILE" ]; then
        local status=$(grep "^Status:" "$MARKER_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
        if [ "$status" = "in-progress" ]; then
            echo "Script interrupted. Cleaning up initialization marker..."
            rm -f "$MARKER_FILE"
        fi
    fi
    exit $exit_code
}

# Set trap to cleanup on script exit/interruption
trap cleanup_on_exit EXIT INT TERM

# Default values
USERNAME="default_user"
PASSWORD=""
INIT_DATA_PATH="$DEFAULT_INIT_DATA_PATH"
VERBOSE="false"
DOCUMENTDB_PORT="10260"
FORCE_REINIT="false"
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
  -f, --force                  Force re-initialization even if already initialized

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
        -f|--force)
            FORCE_REINIT="true"
            shift
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

# Generate marker file path based on INIT_DATA_PATH
# Create a safe filename from the path by replacing / with _ and removing leading _
MARKER_SUFFIX=$(echo "$INIT_DATA_PATH" | sed 's/\//_/g' | sed 's/^_//')
MARKER_FILE="/var/lib/postgresql/data/.documentdb_initialized_${MARKER_SUFFIX}"

log "Using marker file: $MARKER_FILE"

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

# Function to wait for DocumentDB to be ready
wait_for_documentdb() {
    local max_attempts=30
    local attempt=1
    
    echo "Waiting for DocumentDB to be ready at localhost:${DOCUMENTDB_PORT}..."
    
    if ! command -v mongosh >/dev/null 2>&1; then
        echo "Error: mongosh not found. Cannot verify DocumentDB readiness."
        echo "Please install mongosh to use this initialization script."
        return 1
    fi
    
    while [ $attempt -le $max_attempts ]; do
        if mongosh "localhost:${DOCUMENTDB_PORT}" -u "$USERNAME" -p "$PASSWORD" --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "DocumentDB is ready!"
            return 0
        fi
        
        log "Attempt $attempt/$max_attempts failed, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "Error: DocumentDB did not become ready within $(($max_attempts * 2)) seconds"
    echo "This could indicate:"
    echo "  - DocumentDB service is not running"
    echo "  - Incorrect connection parameters (host/port)"
    echo "  - Authentication issues (username/password)"
    echo "Please check the DocumentDB logs for more details."
    return 1
}

# Function to check if initialization has already been performed
is_already_initialized() {
    log "Checking if database has been previously initialized..."
    
    # Check if force re-initialization is requested
    if [ "$FORCE_REINIT" = "true" ]; then
        echo "Force re-initialization requested. Removing existing marker..."
        rm -f "$MARKER_FILE"
        return 1
    fi
    
    # First check the marker file
    if [ -f "$MARKER_FILE" ]; then
        # Check the status in the marker file
        local status=$(grep "^Status:" "$MARKER_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
        
        if [ "$status" = "complete" ]; then
            echo "Database has been previously initialized. Skipping initialization to prevent duplicate data."
            echo "Initialization marker: $MARKER_FILE"
            echo "To re-initialize, remove the marker file: rm $MARKER_FILE"
            echo "Or use the --force flag to force re-initialization"
            return 0
        elif [ "$status" = "in-progress" ]; then
            local marker_age=$(($(date +%s) - $(stat -c %Y "$MARKER_FILE" 2>/dev/null || echo 0)))
            if [ $marker_age -lt 300 ]; then
                echo "Initialization is already in progress."
                echo "Waiting for other process to complete initialization..."
                # Wait for up to 5 minutes for status to change to complete
                local wait_count=0
                while [ $wait_count -lt 150 ]; do
                    sleep 2
                    if [ ! -f "$MARKER_FILE" ]; then
                        echo "Marker file removed by other process. Proceeding with initialization..."
                        return 1
                    fi
                    status=$(grep "^Status:" "$MARKER_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
                    if [ "$status" = "complete" ]; then
                        echo "Initialization completed by another process."
                        return 0
                    fi
                    wait_count=$((wait_count + 1))
                done
                echo "Warning: Timeout waiting for initialization. Proceeding anyway..."
            else
                echo "Stale initialization detected (older than 5 minutes). Re-initializing..."
            fi
        fi
    fi
    
    # If no marker file or stale marker, check if database actually has data
    log "Checking if database contains any initialized data..."
    local db_check_failed=false
    
    # Use jq for robust JSON parsing if available, otherwise use simple output
    if command -v jq >/dev/null 2>&1; then
        log "Using jq for JSON parsing..."
        local db_list=$(mongosh "localhost:${DOCUMENTDB_PORT}" -u "$USERNAME" -p "$PASSWORD" \
            --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates \
            --quiet --eval "print(JSON.stringify(db.getMongo().getDBNames().filter(n => !n.startsWith('admin') && !n.startsWith('config') && !n.startsWith('local'))))" 2>/dev/null) || db_check_failed=true
        
        if [ "$db_check_failed" = "false" ] && [ -n "$db_list" ]; then
            local db_count=$(echo "$db_list" | jq 'length' 2>/dev/null || echo "0")
        else
            db_check_failed=true
        fi
    else
        log "jq not found, using simple count method..."
        local db_count=$(mongosh "localhost:${DOCUMENTDB_PORT}" -u "$USERNAME" -p "$PASSWORD" \
            --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates \
            --quiet --eval "db.getMongo().getDBNames().filter(n => !n.startsWith('admin') && !n.startsWith('config') && !n.startsWith('local')).length" 2>/dev/null) || db_check_failed=true
    fi
    
    if [ "$db_check_failed" = "true" ]; then
        echo "Error: Failed to check database for existing data."
        echo "This indicates an unexpected connection issue after initial connection succeeded."
        echo "Cannot safely proceed with initialization without verifying database state."
        echo "Please check the DocumentDB service and try again."
        exit 1
    fi
    
    if [ "$db_count" != "0" ] && [ -n "$db_count" ]; then
        echo "Database contains existing data but no valid marker file."
        echo "Skipping initialization to prevent duplicate data."
        echo "If you want to re-initialize, please clean the database first or remove the data directory."
        # Create marker file retroactively
        set_init_marker "complete"
        return 0
    fi
    
    log "No initialization marker found and database is empty. Proceeding with initialization..."
    return 1
}

# Function to set initialization marker
set_init_marker() {
    local status="$1"  # "in-progress" or "complete"
    
    # Validate status parameter
    if [ "$status" != "in-progress" ] && [ "$status" != "complete" ]; then
        echo "Error: Invalid status '$status'. Must be 'in-progress' or 'complete'."
        return 1
    fi
    
    if [ "$status" = "in-progress" ]; then
        log "Setting initialization status to: in-progress"
    else
        log "Setting initialization marker to: complete"
    fi
    
    # Create/update marker file with status
    if { echo "Status: $status"; \
         echo "Timestamp: $(date -Iseconds)"; \
         echo "Init data path: $INIT_DATA_PATH"; } > "$MARKER_FILE" 2>/dev/null; then
        log "Initialization marker updated successfully at: $MARKER_FILE"
        return 0
    else
        echo "Warning: Failed to update initialization marker at: $MARKER_FILE"
        echo "This may indicate permission issues with the data directory."
        return 1
    fi
}

# Function to execute initialization scripts from a directory
run_init_scripts() {
    local init_dir="$1"
    local script_count=0
    
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
    
    # Check if initialization has already been performed
    if is_already_initialized; then
        return 0
    fi
    
    # Set marker to "in-progress" state
    if ! set_init_marker "in-progress"; then
        echo "Error: Failed to set initialization marker. Cannot proceed safely."
        return 1
    fi
    
    # Process .js files in alphabetical order
    for init_file in "$init_dir"/*.js; do
        if [ -f "$init_file" ]; then
            script_count=$((script_count + 1))
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
                echo "Please check the script for errors and try again."
                # Remove marker file on failure to allow retry
                rm -f "$MARKER_FILE"
                return 1
            fi
        fi
    done
    
    if [ $script_count -eq 0 ]; then
        echo "No JavaScript files found in: $init_dir"
        # Remove marker file
        rm -f "$MARKER_FILE"
        return 1
    fi
    
    echo "Processed $script_count initialization script(s)"
    
    # Set marker to "complete" state
    if ! set_init_marker "complete"; then
        echo "Warning: Failed to set completion marker. Initialization succeeded but status may not be properly tracked."
    fi
    
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
