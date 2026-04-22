#!/bin/bash

# Script to test the new --init-data feature of DocumentDB
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONTAINER_NAME="documentdb-init-data-test"
IMAGE_NAME="documentdb-init-data-test"
DOCKERFILE_PATH="$PROJECT_ROOT/packaging/gateway/docker/Dockerfile_documentdb_local"
DOCUMENTDB_PORT="10261"  # Use different port to avoid conflicts
PASSWORD="TestPassword123"

echo "=== DocumentDB --init-data Feature Test ==="
echo "Project Root: $PROJECT_ROOT"
echo "Script Directory: $SCRIPT_DIR"
echo "Container: $CONTAINER_NAME"
echo "Image: $IMAGE_NAME"
echo "Dockerfile: $DOCKERFILE_PATH"
echo "DocumentDB Port: $DOCUMENTDB_PORT"
echo

# Function to check if mongosh is available
check_mongosh() {
    echo "=== Checking Prerequisites ==="
    if ! command -v mongosh >/dev/null 2>&1; then
        echo "❌ Error: mongosh is not installed or not in PATH"
        echo "Please install mongosh to run this test."
        echo "Visit: https://docs.mongodb.com/mongodb-shell/install/"
        exit 1
    fi
    echo "✅ mongosh is available: $(mongosh --version)"
    echo
}

# Function to build the Docker image
build_image() {
    echo "=== Building Docker Image ==="
    if [ ! -f "$DOCKERFILE_PATH" ]; then
        echo "❌ Error: Dockerfile not found at $DOCKERFILE_PATH"
        exit 1
    fi
    
    # Check if sample data directory exists in the project
    if [ ! -d "$PROJECT_ROOT/documentdb-local/sample-data" ]; then
        echo "❌ Error: Sample data directory not found at $PROJECT_ROOT/documentdb-local/sample-data"
        echo "Please ensure the sample-data directory exists with the required JavaScript files."
        exit 1
    fi
    
    echo "Sample data files found:"
    ls -la "$PROJECT_ROOT/documentdb-local/sample-data"/*.js
    echo
    
    echo "Building image $IMAGE_NAME from $DOCKERFILE_PATH..."
    docker build -f "$DOCKERFILE_PATH" -t "$IMAGE_NAME" "$PROJECT_ROOT"
    echo "✅ Image built successfully"
    echo
}

# Function to cleanup previous runs
cleanup() {
    echo "Cleaning up previous containers..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    docker stop "${CONTAINER_NAME}-env" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}-env" 2>/dev/null || true
    docker stop "${CONTAINER_NAME}-legacy-env" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}-legacy-env" 2>/dev/null || true
}

# Function to wait for DocumentDB to be ready
wait_for_documentdb() {
    echo "Waiting for DocumentDB to be ready..."
    local max_attempts=60  # Increased timeout for initialization
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "✅ DocumentDB is ready!"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts - waiting..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    echo "❌ Error: DocumentDB did not become ready within timeout"
    return 1
}

# Function to wait for sample data initialization to complete by monitoring logs
wait_for_data_initialization() {
    echo "Waiting for sample data initialization to complete..."
    local max_attempts=120  # 6 minutes timeout for data initialization
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if the completion message appears in container logs
        if docker logs $CONTAINER_NAME 2>&1 | grep -q "Sample data initialization completed!"; then
            echo "✅ Sample data initialization completed!"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts - waiting for data initialization completion log..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    echo "❌ Error: Sample data initialization did not complete within timeout"
    echo "=== Recent Container Logs ==="
    docker logs --tail 20 $CONTAINER_NAME
    return 1
}

# Function to verify sample data was loaded correctly
verify_sample_data() {
    echo "=== Verifying Sample Data Initialization ==="
    
    # Check if sampledb database exists and switch to it
    echo "Checking sampledb database..."
    DB_LIST=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.adminCommand('listDatabases')" --quiet 2>/dev/null)
    
    if [[ "$DB_LIST" == *"sampledb"* ]]; then
        echo "✅ sampledb database found"
    else
        echo "❌ sampledb database not found"
        echo "Available databases:"
        echo "$DB_LIST"
        return 1
    fi
    
    # Check users collection
    echo "Checking users collection..."
    USER_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Users count: $USER_COUNT"
    
    # Check products collection
    echo "Checking products collection..."
    PRODUCT_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.products.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Products count: $PRODUCT_COUNT"
    
    # Check orders collection
    echo "Checking orders collection..."
    ORDER_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.orders.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Orders count: $ORDER_COUNT"
    
    # Check analytics collection
    echo "Checking analytics collection..."
    ANALYTICS_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.analytics.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Analytics count: $ANALYTICS_COUNT"
    
    # Show sample data from each collection
    echo
    echo "=== Sample Data Examples ==="
    echo "Sample user:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.findOne()" --quiet 2>/dev/null | head -10
    
    echo
    echo "Sample product:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.products.findOne()" --quiet 2>/dev/null | head -10
    
    echo
    echo "Sample order:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.orders.findOne()" --quiet 2>/dev/null | head -10
    
    echo
    echo "Sample analytics:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.analytics.findOne()" --quiet 2>/dev/null | head -10
    
    # Verify indexes were created
    echo
    echo "=== Checking Indexes ==="
    echo "Users indexes:"
    USER_INDEXES=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.getIndexes().length" --quiet 2>/dev/null | tail -1)
    echo "Users has $USER_INDEXES indexes"
    
    echo "Products indexes:"
    PRODUCT_INDEXES=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.products.getIndexes().length" --quiet 2>/dev/null | tail -1)
    echo "Products has $PRODUCT_INDEXES indexes"
    
    echo "Orders indexes:"
    ORDER_INDEXES=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.orders.getIndexes().length" --quiet 2>/dev/null | tail -1)
    echo "Orders has $ORDER_INDEXES indexes"
    
    echo "Analytics indexes:"
    ANALYTICS_INDEXES=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.analytics.getIndexes().length" --quiet 2>/dev/null | tail -1)
    echo "Analytics has $ANALYTICS_INDEXES indexes"
    
    # Test some complex queries to verify data relationships
    echo
    echo "=== Testing Data Relationships and Queries ==="
    
    echo "Testing query: Users in Seattle"
    SEATTLE_USERS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.countDocuments({city: 'Seattle'})" --quiet 2>/dev/null | tail -1)
    echo "Users in Seattle: $SEATTLE_USERS"
    
    echo "Testing query: Electronics products"
    ELECTRONICS_PRODUCTS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.products.countDocuments({category: 'Electronics'})" --quiet 2>/dev/null | tail -1)
    echo "Electronics products: $ELECTRONICS_PRODUCTS"
    
    echo "Testing query: Orders with status 'delivered'"
    DELIVERED_ORDERS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.orders.countDocuments({status: 'delivered'})" --quiet 2>/dev/null | tail -1)
    echo "Delivered orders: $DELIVERED_ORDERS"
    
    echo "Testing query: Premium users"
    PREMIUM_USERS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.countDocuments({tags: 'premium'})" --quiet 2>/dev/null | tail -1)
    echo "Premium users: $PREMIUM_USERS"
    
    # Test aggregation pipeline
    echo "Testing aggregation: Total revenue by order status"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "
        use('sampledb'); 
        db.orders.aggregate([
            { \$group: { 
                _id: '\$status', 
                totalRevenue: { \$sum: '\$orderSummary.total' },
                orderCount: { \$sum: 1 }
            }},
            { \$sort: { totalRevenue: -1 }}
        ]).forEach(printjson)
    " --quiet 2>/dev/null
    
    # Return results for validation
    export USER_COUNT PRODUCT_COUNT ORDER_COUNT ANALYTICS_COUNT
    export USER_INDEXES PRODUCT_INDEXES ORDER_INDEXES ANALYTICS_INDEXES
    export SEATTLE_USERS ELECTRONICS_PRODUCTS DELIVERED_ORDERS PREMIUM_USERS
}

# Function to verify sample data is not loaded by default
verify_sample_data_disabled_by_default() {
    echo "=== Verifying Built-in Sample Data Is Disabled By Default ==="

    DB_LIST=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.adminCommand('listDatabases')" --quiet 2>/dev/null)

    if [[ "$DB_LIST" == *"sampledb"* ]]; then
        echo "❌ sampledb database found unexpectedly"
        echo "Available databases:"
        echo "$DB_LIST"
        return 1
    fi

    echo "✅ sampledb database not found"

    if docker logs $CONTAINER_NAME 2>&1 | grep -q "Initializing database with built-in sample data"; then
        echo "❌ Built-in sample data initialization ran unexpectedly"
        return 1
    fi

    echo "✅ Built-in sample data initialization did not run"
    return 0
}

# Function to wait for a container to stop after argument validation fails
wait_for_container_to_stop() {
    local max_attempts=15
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if ! docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
            echo "✅ Container stopped as expected"
            return 0
        fi

        echo "Attempt $attempt/$max_attempts - waiting for container to stop..."
        sleep 1
        attempt=$((attempt + 1))
    done

    echo "❌ Container did not stop within timeout"
    docker logs $CONTAINER_NAME
    return 1
}

# Function to test the legacy --skip-init-data alias still overrides older env usage
test_skip_init_data_legacy_alias() {
    echo
    echo "=== Testing Legacy Alias (--skip-init-data) ==="

    cleanup

    echo "Starting container with INIT_DATA=true and --skip-init-data..."
    docker run -d \
        --name $CONTAINER_NAME \
        -p $DOCUMENTDB_PORT:10260 \
        -e PASSWORD=$PASSWORD \
        -e INIT_DATA=true \
        $IMAGE_NAME \
        --password $PASSWORD \
        --skip-init-data

    echo "Container started with ID: $(docker ps -q -f name=$CONTAINER_NAME)"
    echo

    if ! wait_for_documentdb; then
        echo "❌ Legacy alias test container failed to start"
        docker logs $CONTAINER_NAME
        return 1
    fi

    if ! verify_sample_data_disabled_by_default; then
        echo "❌ Legacy alias test failed"
        return 1
    fi

    echo "✅ Legacy alias test passed"
    return 0
}

# Function to validate invalid values are rejected before startup continues
test_invalid_init_data_value() {
    echo
    echo "=== Testing Invalid --init-data Value ==="

    cleanup

    echo "Starting DocumentDB container with --init-data maybe..."
    docker run -d \
        --name $CONTAINER_NAME \
        -p $DOCUMENTDB_PORT:10260 \
        -e PASSWORD=$PASSWORD \
        $IMAGE_NAME \
        --password $PASSWORD \
        --init-data maybe

    if ! wait_for_container_to_stop; then
        echo "❌ Invalid value test failed because the container stayed running"
        return 1
    fi

    INVALID_EXIT_CODE=$(docker inspect $CONTAINER_NAME --format='{{.State.ExitCode}}')
    if [ "$INVALID_EXIT_CODE" != "1" ]; then
        echo "❌ Invalid value test failed: expected exit code 1, found $INVALID_EXIT_CODE"
        docker logs $CONTAINER_NAME
        return 1
    fi

    if ! docker logs $CONTAINER_NAME 2>&1 | grep -q "Invalid init-data value maybe, must be true or false"; then
        echo "❌ Invalid value test failed: expected validation message not found"
        docker logs $CONTAINER_NAME
        return 1
    fi

    echo "✅ Invalid value was rejected with the expected message"
    return 0
}

# Function to test environment variable usage
test_environment_variable() {
    echo
    echo "=== Testing Environment Variable (INIT_DATA) ==="
    
    # Cleanup first
    cleanup
    
    # Test with environment variable instead of command line flag
    echo "Starting container with INIT_DATA environment variable..."
    docker run -d \
        --name "${CONTAINER_NAME}-env" \
        -p $((DOCUMENTDB_PORT + 1)):10260 \
        -e PASSWORD=$PASSWORD \
        -e INIT_DATA=true \
        $IMAGE_NAME \
        --password $PASSWORD
    
    ENV_CONTAINER_NAME="${CONTAINER_NAME}-env"
    ENV_PORT=$((DOCUMENTDB_PORT + 1))
    
    echo "Waiting for environment variable test container to be ready..."
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if mongosh localhost:$ENV_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "✅ Environment variable test container is ready!"
            break
        fi
        
        echo "Attempt $attempt/$max_attempts - waiting..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo "❌ Environment variable test container failed to start"
        docker logs $ENV_CONTAINER_NAME
        return 1
    fi
    
    # Wait for data initialization to complete by monitoring logs
    echo "Waiting for sample data initialization to complete in environment test..."
    local data_max_attempts=120
    local data_attempt=1
    
    while [ $data_attempt -le $data_max_attempts ]; do
        if docker logs $ENV_CONTAINER_NAME 2>&1 | grep -q "Sample data initialization completed!"; then
            echo "✅ Environment test data initialization completed!"
            break
        fi
        
        echo "Environment test attempt $data_attempt/$data_max_attempts - waiting for initialization completion log..."
        sleep 3
        data_attempt=$((data_attempt + 1))
    done
    
    if [ $data_attempt -gt $data_max_attempts ]; then
        echo "❌ Environment test data initialization failed"
        docker logs --tail 20 $ENV_CONTAINER_NAME
        return 1
    fi
    
    # Quick verification
    ENV_USER_COUNT=$(mongosh localhost:$ENV_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)
    
    # Cleanup environment test container
    docker stop $ENV_CONTAINER_NAME 2>/dev/null || true
    docker rm $ENV_CONTAINER_NAME 2>/dev/null || true
    
    if [ "$ENV_USER_COUNT" = "5" ]; then
        echo "✅ Environment variable test passed (found $ENV_USER_COUNT users)"
        return 0
    else
        echo "❌ Environment variable test failed (found $ENV_USER_COUNT users, expected 5)"
        return 1
    fi
}

# Function to test the legacy SKIP_INIT_DATA=false environment variable still enables sample data
test_skip_init_data_false_environment_variable() {
    echo
    echo "=== Testing Legacy Environment Variable (SKIP_INIT_DATA=false) ==="

    cleanup

    echo "Starting container with SKIP_INIT_DATA=false environment variable..."
    docker run -d \
        --name "${CONTAINER_NAME}-legacy-env" \
        -p $((DOCUMENTDB_PORT + 2)):10260 \
        -e PASSWORD=$PASSWORD \
        -e SKIP_INIT_DATA=false \
        $IMAGE_NAME \
        --password $PASSWORD

    LEGACY_ENV_CONTAINER_NAME="${CONTAINER_NAME}-legacy-env"
    LEGACY_ENV_PORT=$((DOCUMENTDB_PORT + 2))

    echo "Waiting for legacy environment variable test container to be ready..."
    local max_attempts=60
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if mongosh localhost:$LEGACY_ENV_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "✅ Legacy environment variable test container is ready!"
            break
        fi

        echo "Attempt $attempt/$max_attempts - waiting..."
        sleep 3
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo "❌ Legacy environment variable test container failed to start"
        docker logs $LEGACY_ENV_CONTAINER_NAME
        return 1
    fi

    echo "Waiting for sample data initialization to complete in legacy environment test..."
    local data_max_attempts=120
    local data_attempt=1

    while [ $data_attempt -le $data_max_attempts ]; do
        if docker logs $LEGACY_ENV_CONTAINER_NAME 2>&1 | grep -q "Sample data initialization completed!"; then
            echo "✅ Legacy environment test data initialization completed!"
            break
        fi

        echo "Legacy environment test attempt $data_attempt/$data_max_attempts - waiting for initialization completion log..."
        sleep 3
        data_attempt=$((data_attempt + 1))
    done

    if [ $data_attempt -gt $data_max_attempts ]; then
        echo "❌ Legacy environment test data initialization failed"
        docker logs --tail 20 $LEGACY_ENV_CONTAINER_NAME
        return 1
    fi

    LEGACY_ENV_USER_COUNT=$(mongosh localhost:$LEGACY_ENV_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('sampledb'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)

    docker stop $LEGACY_ENV_CONTAINER_NAME 2>/dev/null || true
    docker rm $LEGACY_ENV_CONTAINER_NAME 2>/dev/null || true

    if [ "$LEGACY_ENV_USER_COUNT" = "5" ]; then
        echo "✅ Legacy environment variable test passed (found $LEGACY_ENV_USER_COUNT users)"
        return 0
    else
        echo "❌ Legacy environment variable test failed (found $LEGACY_ENV_USER_COUNT users, expected 5)"
        return 1
    fi
}

# Main test execution
main() {
    # Check prerequisites
    check_mongosh
    
    # Cleanup any previous test runs
    cleanup
    
    # Build the Docker image
    build_image
    
    # Test 1: Default startup should not load sample data
    echo "=== Test 1: Default Startup (no sample data) ==="
    echo "Starting DocumentDB container without built-in sample data..."
    docker run -d \
        --name $CONTAINER_NAME \
        -p $DOCUMENTDB_PORT:10260 \
        -e PASSWORD=$PASSWORD \
        $IMAGE_NAME \
        --password $PASSWORD

    echo "Container started with ID: $(docker ps -q -f name=$CONTAINER_NAME)"
    echo

    if wait_for_documentdb; then
        if verify_sample_data_disabled_by_default; then
            echo "✅ Default startup verification completed"
            DEFAULT_OFF_RESULT=0
        else
            echo "❌ Default startup verification failed"
            return 1
        fi
    else
        echo "❌ Default startup failed"
        docker logs $CONTAINER_NAME
        return 1
    fi

    cleanup

    # Test 2: Legacy alias --skip-init-data
    if test_skip_init_data_legacy_alias; then
        echo "✅ Legacy alias verification completed"
        SKIP_ALIAS_RESULT=0
    else
        echo "❌ Legacy alias verification failed"
        cleanup
        return 1
    fi

    cleanup

    # Test 3: Invalid value should be rejected
    if test_invalid_init_data_value; then
        echo "✅ Invalid value verification completed"
        INVALID_VALUE_RESULT=0
    else
        echo "❌ Invalid value verification failed"
        cleanup
        return 1
    fi

    cleanup

    # Test 4: Command line flag --init-data true
    echo "=== Test 4: Command Line Flag (--init-data true) ==="
    echo "Starting DocumentDB container with --init-data true..."
    docker run -d \
        --name $CONTAINER_NAME \
        -p $DOCUMENTDB_PORT:10260 \
        -e PASSWORD=$PASSWORD \
        $IMAGE_NAME \
        --password $PASSWORD \
        --init-data true
    
    echo "Container started with ID: $(docker ps -q -f name=$CONTAINER_NAME)"
    echo
    
    # Wait for the container to be ready
    if wait_for_documentdb; then
        # Wait for sample data initialization to complete by monitoring logs
        if wait_for_data_initialization; then
            echo "✅ DocumentDB and sample data are ready!"
        else
            echo "❌ Sample data initialization failed"
            return 1
        fi
        
        # Verify the sample data was loaded
        if verify_sample_data; then
            echo "✅ Sample data verification completed"
        else
            echo "❌ Sample data verification failed"
            return 1
        fi
        
        # Test 5: Environment variable
        test_environment_variable
        ENV_TEST_RESULT=$?

        # Test 6: Legacy environment variable still enables sample data
        test_skip_init_data_false_environment_variable
        LEGACY_ENV_TEST_RESULT=$?
        
        echo
        echo "=== Test Results Summary ==="
        
        # Expected values based on our sample data
        EXPECTED_DEFAULT_OFF="PASS"
        EXPECTED_SKIP_ALIAS="PASS"
        EXPECTED_INVALID_VALUE="PASS"
        EXPECTED_LEGACY_ENV="PASS"
        EXPECTED_USERS=5
        EXPECTED_PRODUCTS=5
        EXPECTED_ORDERS=4
        EXPECTED_ANALYTICS=2
        EXPECTED_SEATTLE_USERS=1
        EXPECTED_ELECTRONICS=2
        EXPECTED_DELIVERED=1
        EXPECTED_PREMIUM=3
        
        # Minimum expected indexes (including default _id index)
        MIN_USER_INDEXES=5  # _id + email + username + city + tags
        MIN_PRODUCT_INDEXES=6  # _id + category + brand + price + tags + sku
        MIN_ORDER_INDEXES=6  # _id + userId + orderNumber + status + orderDate + customerInfo.email
        MIN_ANALYTICS_INDEXES=4  # _id + period + type + date
        
        # Test results
        DEFAULT_OFF_PASS=$([[ "$DEFAULT_OFF_RESULT" == "0" ]] && echo "✅" || echo "❌")
        SKIP_ALIAS_PASS=$([[ "$SKIP_ALIAS_RESULT" == "0" ]] && echo "✅" || echo "❌")
        INVALID_VALUE_PASS=$([[ "$INVALID_VALUE_RESULT" == "0" ]] && echo "✅" || echo "❌")
        LEGACY_ENV_PASS=$([[ "$LEGACY_ENV_TEST_RESULT" == "0" ]] && echo "✅" || echo "❌")
        USERS_PASS=$([[ "$USER_COUNT" == "$EXPECTED_USERS" ]] && echo "✅" || echo "❌")
        PRODUCTS_PASS=$([[ "$PRODUCT_COUNT" == "$EXPECTED_PRODUCTS" ]] && echo "✅" || echo "❌")
        ORDERS_PASS=$([[ "$ORDER_COUNT" == "$EXPECTED_ORDERS" ]] && echo "✅" || echo "❌")
        ANALYTICS_PASS=$([[ "$ANALYTICS_COUNT" == "$EXPECTED_ANALYTICS" ]] && echo "✅" || echo "❌")
        SEATTLE_PASS=$([[ "$SEATTLE_USERS" == "$EXPECTED_SEATTLE_USERS" ]] && echo "✅" || echo "❌")
        ELECTRONICS_PASS=$([[ "$ELECTRONICS_PRODUCTS" == "$EXPECTED_ELECTRONICS" ]] && echo "✅" || echo "❌")
        DELIVERED_PASS=$([[ "$DELIVERED_ORDERS" == "$EXPECTED_DELIVERED" ]] && echo "✅" || echo "❌")
        PREMIUM_PASS=$([[ "$PREMIUM_USERS" == "$EXPECTED_PREMIUM" ]] && echo "✅" || echo "❌")
        USER_IDX_PASS=$([[ "$USER_INDEXES" -ge "$MIN_USER_INDEXES" ]] && echo "✅" || echo "❌")
        PRODUCT_IDX_PASS=$([[ "$PRODUCT_INDEXES" -ge "$MIN_PRODUCT_INDEXES" ]] && echo "✅" || echo "❌")
        ORDER_IDX_PASS=$([[ "$ORDER_INDEXES" -ge "$MIN_ORDER_INDEXES" ]] && echo "✅" || echo "❌")
        ANALYTICS_IDX_PASS=$([[ "$ANALYTICS_INDEXES" -ge "$MIN_ANALYTICS_INDEXES" ]] && echo "✅" || echo "❌")
        ENV_PASS=$([[ "$ENV_TEST_RESULT" == "0" ]] && echo "✅" || echo "❌")
        
        echo "┌─────────────────────────────────┬──────────┬──────────┬────────┐"
        echo "│ Test Case                       │ Expected │ Actual   │ Result │"
        echo "├─────────────────────────────────┼──────────┼──────────┼────────┤"
        echo "│ Default Startup                 │ $EXPECTED_DEFAULT_OFF     │ $([ "$DEFAULT_OFF_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $DEFAULT_OFF_PASS     │"
        echo "│ Legacy Alias (--skip-init-data) │ $EXPECTED_SKIP_ALIAS     │ $([ "$SKIP_ALIAS_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $SKIP_ALIAS_PASS     │"
        echo "│ Invalid --init-data Value       │ $EXPECTED_INVALID_VALUE     │ $([ "$INVALID_VALUE_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $INVALID_VALUE_PASS     │"
        echo "│ Legacy Env (SKIP_INIT_DATA=false) │ $EXPECTED_LEGACY_ENV     │ $([ "$LEGACY_ENV_TEST_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $LEGACY_ENV_PASS     │"
        echo "│ Users Collection                │ $EXPECTED_USERS        │ $USER_COUNT        │ $USERS_PASS     │"
        echo "│ Products Collection             │ $EXPECTED_PRODUCTS        │ $PRODUCT_COUNT        │ $PRODUCTS_PASS     │"
        echo "│ Orders Collection               │ $EXPECTED_ORDERS        │ $ORDER_COUNT        │ $ORDERS_PASS     │"
        echo "│ Analytics Collection            │ $EXPECTED_ANALYTICS        │ $ANALYTICS_COUNT        │ $ANALYTICS_PASS     │"
        echo "│ Seattle Users Query             │ $EXPECTED_SEATTLE_USERS        │ $SEATTLE_USERS        │ $SEATTLE_PASS     │"
        echo "│ Electronics Products Query      │ $EXPECTED_ELECTRONICS        │ $ELECTRONICS_PRODUCTS        │ $ELECTRONICS_PASS     │"
        echo "│ Delivered Orders Query          │ $EXPECTED_DELIVERED        │ $DELIVERED_ORDERS        │ $DELIVERED_PASS     │"
        echo "│ Premium Users Query             │ $EXPECTED_PREMIUM        │ $PREMIUM_USERS        │ $PREMIUM_PASS     │"
        echo "│ Users Indexes (min $MIN_USER_INDEXES)           │ >=$MIN_USER_INDEXES       │ $USER_INDEXES        │ $USER_IDX_PASS     │"
        echo "│ Products Indexes (min $MIN_PRODUCT_INDEXES)        │ >=$MIN_PRODUCT_INDEXES       │ $PRODUCT_INDEXES        │ $PRODUCT_IDX_PASS     │"
        echo "│ Orders Indexes (min $MIN_ORDER_INDEXES)          │ >=$MIN_ORDER_INDEXES       │ $ORDER_INDEXES        │ $ORDER_IDX_PASS     │"
        echo "│ Analytics Indexes (min $MIN_ANALYTICS_INDEXES)       │ >=$MIN_ANALYTICS_INDEXES       │ $ANALYTICS_INDEXES        │ $ANALYTICS_IDX_PASS     │"
        echo "│ Environment Variable Test       │ PASS     │ $([ "$ENV_TEST_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $ENV_PASS     │"
        echo "└─────────────────────────────────┴──────────┴──────────┴────────┘"
        echo
        
        # Overall result
        ALL_TESTS_PASSED=true
        
        # Check all conditions
        [ "$DEFAULT_OFF_RESULT" != "0" ] && ALL_TESTS_PASSED=false
        [ "$SKIP_ALIAS_RESULT" != "0" ] && ALL_TESTS_PASSED=false
        [ "$INVALID_VALUE_RESULT" != "0" ] && ALL_TESTS_PASSED=false
        [ "$LEGACY_ENV_TEST_RESULT" != "0" ] && ALL_TESTS_PASSED=false
        [ "$USER_COUNT" != "$EXPECTED_USERS" ] && ALL_TESTS_PASSED=false
        [ "$PRODUCT_COUNT" != "$EXPECTED_PRODUCTS" ] && ALL_TESTS_PASSED=false
        [ "$ORDER_COUNT" != "$EXPECTED_ORDERS" ] && ALL_TESTS_PASSED=false
        [ "$ANALYTICS_COUNT" != "$EXPECTED_ANALYTICS" ] && ALL_TESTS_PASSED=false
        [ "$SEATTLE_USERS" != "$EXPECTED_SEATTLE_USERS" ] && ALL_TESTS_PASSED=false
        [ "$ELECTRONICS_PRODUCTS" != "$EXPECTED_ELECTRONICS" ] && ALL_TESTS_PASSED=false
        [ "$DELIVERED_ORDERS" != "$EXPECTED_DELIVERED" ] && ALL_TESTS_PASSED=false
        [ "$PREMIUM_USERS" != "$EXPECTED_PREMIUM" ] && ALL_TESTS_PASSED=false
        [ "$USER_INDEXES" -lt "$MIN_USER_INDEXES" ] && ALL_TESTS_PASSED=false
        [ "$PRODUCT_INDEXES" -lt "$MIN_PRODUCT_INDEXES" ] && ALL_TESTS_PASSED=false
        [ "$ORDER_INDEXES" -lt "$MIN_ORDER_INDEXES" ] && ALL_TESTS_PASSED=false
        [ "$ANALYTICS_INDEXES" -lt "$MIN_ANALYTICS_INDEXES" ] && ALL_TESTS_PASSED=false
        [ "$ENV_TEST_RESULT" != "0" ] && ALL_TESTS_PASSED=false
        
        if [ "$ALL_TESTS_PASSED" = true ]; then
            echo "🎉 OVERALL RESULT: SUCCESS! All tests passed."
            echo "✅ Docker build completed successfully"
            echo "✅ Container started and initialized properly"
            echo "✅ Default startup does not load built-in sample data"
            echo "✅ Legacy --skip-init-data alias still works"
            echo "✅ Invalid --init-data values are rejected"
            echo "✅ Legacy SKIP_INIT_DATA=false environment variable still enables sample data"
            echo "✅ All sample collections created with expected data"
            echo "✅ All indexes created successfully"
            echo "✅ All queries work as expected"
            echo "✅ Data relationships are correct"
            echo "✅ Environment variable works correctly"
            echo "✅ --init-data feature is working perfectly!"
            OVERALL_RESULT="SUCCESS"
        else
            echo "❌ OVERALL RESULT: FAILURE! Some tests failed."
            echo "Please check the detailed results above."
            OVERALL_RESULT="FAILURE"
            
            # Show container logs for debugging
            echo
            echo "=== Container Logs (last 100 lines) ==="
            docker logs --tail 100 $CONTAINER_NAME
        fi
    else
        echo "❌ OVERALL RESULT: FAILURE! DocumentDB failed to start properly"
        echo
        echo "=== Container Logs ==="
        docker logs $CONTAINER_NAME
        OVERALL_RESULT="FAILURE"
    fi
    
    echo
    echo "=== Post-Test Information ==="
    echo "Stopping and cleaning up the test containers..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    docker stop "${CONTAINER_NAME}-env" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}-env" 2>/dev/null || true
    echo "✅ Containers stopped and removed successfully"
    echo
    echo "To manually explore the sample data:"
    echo "1. Start container: docker run -d --name documentdb-manual -p 10260:10260 -e PASSWORD=mypass $IMAGE_NAME --password mypass --init-data true"
    echo "2. Connect: mongosh localhost:10260 -u default_user -p mypass --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates"
    echo "3. Use database: use('sampledb')"
    echo "4. Explore: db.users.find(), db.products.find(), db.orders.find(), db.analytics.find()"
    echo
    echo "Cleanup commands:"
    echo "1. Remove container: docker rm $CONTAINER_NAME"
    echo "2. Remove image: docker rmi $IMAGE_NAME"
    echo
    
    # Exit with appropriate code
    if [ "$OVERALL_RESULT" = "SUCCESS" ]; then
        exit 0
    else
        exit 1
    fi
}

# Run the test
main "$@"
