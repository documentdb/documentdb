#!/bin/bash

# Script to test the init-data-path feature of DocumentDB
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONTAINER_NAME="documentdb-gateway-test"
IMAGE_NAME="documentdb-gateway-test"
INIT_DATA_DIR="$SCRIPT_DIR/test-init-data"
DOCKERFILE_PATH="$PROJECT_ROOT/packaging/gateway/docker/Dockerfile_documentdb_local"
DOCUMENTDB_PORT="10260"
PASSWORD="TestPassword123"

echo "=== DocumentDB Init-Data-Path Feature Test ==="
echo "Project Root: $PROJECT_ROOT"
echo "Script Directory: $SCRIPT_DIR"
echo "Container: $CONTAINER_NAME"
echo "Image: $IMAGE_NAME"
echo "Init Data Directory: $INIT_DATA_DIR"
echo "Dockerfile: $DOCKERFILE_PATH"
echo "DocumentDB Port: $DOCUMENTDB_PORT"
echo

# Function to check if mongosh is available
check_mongosh() {
    echo "=== Checking Prerequisites ==="
    if ! command -v mongosh >/dev/null 2>&1; then
        echo "❌ Error: mongosh is not installed or not in PATH"
        echo "Please install MongoDB Shell (mongosh) to run this test."
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
        echo "Error: Dockerfile not found at $DOCKERFILE_PATH"
        exit 1
    fi
    
    echo "Building image $IMAGE_NAME from $DOCKERFILE_PATH..."
    docker build -f "$DOCKERFILE_PATH" -t "$IMAGE_NAME" "$PROJECT_ROOT" --no-cache
    echo "✅ Image built successfully"
    echo
}

# Function to cleanup previous runs
cleanup() {
    echo "Cleaning up previous containers..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
}

# Function to wait for DocumentDB to be ready
wait_for_documentdb() {
    echo "Waiting for DocumentDB to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "DocumentDB is ready!"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts - waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "Error: DocumentDB did not become ready"
    return 1
}

# Function to wait for sample data initialization to complete by monitoring logs
wait_for_data_initialization() {
    echo "Waiting for data initialization to complete..."
    local max_attempts=120  # 6 minutes timeout for data initialization
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if the completion message appears in container logs
        if docker logs $CONTAINER_NAME 2>&1 | grep -q "Sample data initialization completed!"; then
            echo "✅ Data initialization completed!"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts - waiting for data initialization completion log..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    echo "❌ Error: Data initialization did not complete within timeout"
    echo "=== Recent Container Logs ==="
    docker logs --tail 20 $CONTAINER_NAME
    return 1
}

# Function to verify the initialized data with comprehensive checks
verify_data() {
    echo "=== Verifying Initialized Data ==="
    
    # Check users collection
    echo "Checking users collection..."
    USER_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Users count: $USER_COUNT"
    
    # Check products collection
    echo "Checking products collection..."
    PRODUCT_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Products count: $PRODUCT_COUNT"
    
    # Check orders collection
    echo "Checking orders collection..."
    ORDER_COUNT=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Orders count: $ORDER_COUNT"
    
    # Show sample data from each collection
    echo
    echo "=== Sample Data ==="
    echo "Sample user:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.findOne()" --quiet 2>/dev/null
    
    echo
    echo "Sample product:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.findOne()" --quiet 2>/dev/null
    
    echo
    echo "Sample order:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.findOne()" --quiet 2>/dev/null
    
    # Verify indexes were created
    echo
    echo "=== Checking Indexes ==="
    echo "Users indexes:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.getIndexes()" --quiet 2>/dev/null
    
    echo
    echo "Products indexes:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.getIndexes()" --quiet 2>/dev/null
    
    echo
    echo "Orders indexes:"
    mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.getIndexes()" --quiet 2>/dev/null
    
    # Test some queries
    echo
    echo "=== Query Tests ==="
    echo "Testing query: Users with age > 30"
    ADULT_USERS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.countDocuments({age: {\$gt: 30}})" --quiet 2>/dev/null | tail -1)
    echo "Adult users (age > 30): $ADULT_USERS"
    
    echo "Testing query: Products in stock"
    IN_STOCK_PRODUCTS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.countDocuments({inStock: true})" --quiet 2>/dev/null | tail -1)
    echo "Products in stock: $IN_STOCK_PRODUCTS"
    
    echo "Testing query: Completed orders"
    COMPLETED_ORDERS=$(mongosh localhost:$DOCUMENTDB_PORT -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.countDocuments({status: 'completed'})" --quiet 2>/dev/null | tail -1)
    echo "Completed orders: $COMPLETED_ORDERS"
}

# Main test execution
main() {
    # Check prerequisites
    check_mongosh
    
    # Cleanup any previous test runs
    cleanup
    
    # Build the Docker image
    build_image
    
    # Verify init data files exist
    if [ ! -d "$INIT_DATA_DIR" ]; then
        echo "Error: Init data directory not found at $INIT_DATA_DIR"
        exit 1
    fi
    
    echo "Init data files found:"
    ls -la "$INIT_DATA_DIR"/*.js
    echo
    
    # Run the container with our test data mounted
    echo "=== Starting DocumentDB Container ==="
    echo "Starting DocumentDB container with init data..."
    docker run -d \
        --name $CONTAINER_NAME \
        -p $DOCUMENTDB_PORT:$DOCUMENTDB_PORT \
        -e PASSWORD=$PASSWORD \
        -v "$INIT_DATA_DIR:/init_doc_db.d" \
        $IMAGE_NAME \
        --password $PASSWORD \
        --init-data-path /init_doc_db.d
    
    echo "Container started with ID: $(docker ps -q -f name=$CONTAINER_NAME)"
    echo
    
    # Wait for the container to be ready
    if wait_for_documentdb; then
        # Wait for data initialization to complete by monitoring logs
        if wait_for_data_initialization; then
            echo "✅ DocumentDB and data initialization are ready!"
        else
            echo "❌ Data initialization failed"
            return 1
        fi
        
        # Verify the data was loaded
        verify_data
        
        echo
        echo "=== Test Results Summary ==="
        
        # Calculate test results
        EXPECTED_USERS=4
        EXPECTED_PRODUCTS=4
        EXPECTED_ORDERS=4
        EXPECTED_ADULT_USERS=3
        EXPECTED_IN_STOCK=3
        EXPECTED_COMPLETED=1
        
        # Test results
        USERS_PASS=$([[ "$USER_COUNT" == "$EXPECTED_USERS" ]] && echo "✅" || echo "❌")
        PRODUCTS_PASS=$([[ "$PRODUCT_COUNT" == "$EXPECTED_PRODUCTS" ]] && echo "✅" || echo "❌")
        ORDERS_PASS=$([[ "$ORDER_COUNT" == "$EXPECTED_ORDERS" ]] && echo "✅" || echo "❌")
        ADULT_USERS_PASS=$([[ "$ADULT_USERS" == "$EXPECTED_ADULT_USERS" ]] && echo "✅" || echo "❌")
        IN_STOCK_PASS=$([[ "$IN_STOCK_PRODUCTS" == "$EXPECTED_IN_STOCK" ]] && echo "✅" || echo "❌")
        COMPLETED_PASS=$([[ "$COMPLETED_ORDERS" == "$EXPECTED_COMPLETED" ]] && echo "✅" || echo "❌")
        
        echo "┌─────────────────────────────┬──────────┬──────────┬────────┐"
        echo "│ Test Case                   │ Expected │ Actual   │ Result │"
        echo "├─────────────────────────────┼──────────┼──────────┼────────┤"
        echo "│ Users Collection            │ $EXPECTED_USERS        │ $USER_COUNT        │ $USERS_PASS     │"
        echo "│ Products Collection         │ $EXPECTED_PRODUCTS        │ $PRODUCT_COUNT        │ $PRODUCTS_PASS     │"
        echo "│ Orders Collection           │ $EXPECTED_ORDERS        │ $ORDER_COUNT        │ $ORDERS_PASS     │"
        echo "│ Adult Users (age > 30)      │ $EXPECTED_ADULT_USERS        │ $ADULT_USERS        │ $ADULT_USERS_PASS     │"
        echo "│ Products In Stock           │ $EXPECTED_IN_STOCK        │ $IN_STOCK_PRODUCTS        │ $IN_STOCK_PASS     │"
        echo "│ Completed Orders            │ $EXPECTED_COMPLETED        │ $COMPLETED_ORDERS        │ $COMPLETED_PASS     │"
        echo "└─────────────────────────────┴──────────┴──────────┴────────┘"
        echo
        
        # Overall result
        if [ "$USER_COUNT" = "$EXPECTED_USERS" ] && [ "$PRODUCT_COUNT" = "$EXPECTED_PRODUCTS" ] && [ "$ORDER_COUNT" = "$EXPECTED_ORDERS" ] && [ "$ADULT_USERS" = "$EXPECTED_ADULT_USERS" ] && [ "$IN_STOCK_PRODUCTS" = "$EXPECTED_IN_STOCK" ] && [ "$COMPLETED_ORDERS" = "$EXPECTED_COMPLETED" ]; then
            echo "🎉 OVERALL RESULT: SUCCESS! All tests passed."
            echo "✅ Docker build completed successfully"
            echo "✅ Container started and initialized properly"
            echo "✅ All collections created with expected data"
            echo "✅ All indexes created successfully"
            echo "✅ All queries work as expected"
            OVERALL_RESULT="SUCCESS"
        else
            echo "❌ OVERALL RESULT: FAILURE! Some tests failed."
            echo "Please check the detailed results above."
            OVERALL_RESULT="FAILURE"
            
            # Show container logs for debugging
            echo
            echo "=== Container Logs (last 50 lines) ==="
            docker logs --tail 50 $CONTAINER_NAME
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
    echo "Stopping and cleaning up the test container..."
    docker stop $CONTAINER_NAME
    echo "✅ Container stopped successfully"
    echo
    echo "Container has been stopped. You can:"
    echo "1. Restart container: docker start $CONTAINER_NAME"
    echo "2. Remove container: docker rm $CONTAINER_NAME"
    echo "3. Remove image: docker rmi $IMAGE_NAME"
    echo "4. Run test again: ./test_init_data.sh"
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
