#!/bin/bash

# Comprehensive end-to-end test for the DocumentDB gateway Docker image.
# Tests all documented features to ensure image correctness.
#
# Usage:
#   ./test_gateway_e2e.sh [--image IMAGE_NAME] [--port PORT]
#
# If --image is not provided, builds from the local Dockerfile.
# Requires: mongosh, docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
IMAGE_NAME=""
BUILD_IMAGE=true
DOCKERFILE_PATH="$PROJECT_ROOT/.github/containers/Build-Ubuntu/Dockerfile_gateway"
BASE_PORT=10260
PASSWORD="TestPassword123"
USERNAME="testuser"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            IMAGE_NAME="$2"
            BUILD_IMAGE=false
            shift 2
            ;;
        --port)
            BASE_PORT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--image IMAGE_NAME] [--port BASE_PORT]"
            echo "  --image   Pre-built image to test (skips build)"
            echo "  --port    Base port for test containers (default: 10260)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================
# Test infrastructure
# ============================================================

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
RESULTS=()

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    RESULTS+=("✅ $1")
    echo "✅ PASS: $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    RESULTS+=("❌ $1: $2")
    echo "❌ FAIL: $1 — $2"
}

# Run mongosh --eval against a connection, return last line of output
ms() {
    local port=$1
    local user=$2
    local pass=$3
    local js=$4
    mongosh --quiet --norc --eval "$js" \
        "mongodb://${user}:${pass}@localhost:${port}/?tls=true&tlsAllowInvalidCertificates=true" \
        2>/dev/null | tail -1
}

cleanup_container() {
    docker rm -f "$1" 2>/dev/null || true
}

wait_ready() {
    local container=$1
    local timeout=${2:-120}
    for i in $(seq 1 "$timeout"); do
        if docker logs "$container" 2>&1 | grep -q "=== DocumentDB is ready ==="; then
            return 0
        fi
        sleep 1
    done
    echo "TIMEOUT: Container $container not ready within ${timeout}s"
    docker logs --tail 20 "$container" 2>&1
    return 1
}

wait_sample_data() {
    local container=$1
    local timeout=${2:-120}
    for i in $(seq 1 "$timeout"); do
        if docker logs "$container" 2>&1 | grep -q "Sample data initialization completed"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ============================================================
# Prerequisites
# ============================================================

echo "=== DocumentDB Gateway E2E Test Suite ==="
echo ""

if ! command -v mongosh >/dev/null 2>&1; then
    echo "❌ Error: mongosh is not installed or not in PATH"
    exit 1
fi
echo "✅ mongosh $(mongosh --version) available"

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Error: docker is not installed or not in PATH"
    exit 1
fi
echo "✅ docker available"

# ============================================================
# Build image if needed
# ============================================================

if [ "$BUILD_IMAGE" = true ]; then
    IMAGE_NAME="documentdb-e2e-test:latest"
    echo ""
    echo "=== Building Docker Image ==="
    docker build -f "$DOCKERFILE_PATH" -t "$IMAGE_NAME" "$PROJECT_ROOT"
    echo "✅ Image built: $IMAGE_NAME"
fi

echo ""
echo "Testing image: $IMAGE_NAME"
echo "Base port: $BASE_PORT"
echo ""

# ============================================================
# PHASE 1: Main container — startup, data ops, system integrity
# ============================================================

MAIN_CONTAINER="e2e-main-$$"
MAIN_PORT=$BASE_PORT

echo "=============================================="
echo "  PHASE 1: Main Container Tests"
echo "=============================================="

cleanup_container "$MAIN_CONTAINER"
docker run -dt --name "$MAIN_CONTAINER" -p "${MAIN_PORT}:10260" \
    "$IMAGE_NAME" --username "$USERNAME" --password "$PASSWORD"

if wait_ready "$MAIN_CONTAINER"; then
    pass "1.1 Container startup"
else
    fail "1.1 Container startup" "not ready"
    echo "FATAL: Cannot continue without a running container"
    cleanup_container "$MAIN_CONTAINER"
    exit 1
fi

if wait_sample_data "$MAIN_CONTAINER"; then
    pass "1.2 Sample data initialization"
else
    fail "1.2 Sample data initialization" "not completed"
fi

# --- Credentials ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" 'print(db.runCommand({ping:1}).ok)')
[ "$R" = "1" ] && pass "2.1 Authentication with custom credentials" || fail "2.1 Authentication" "$R"

# --- Wire protocol ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
let p=db.runCommand({ping:1}).ok;
let h=db.runCommand({hello:1}).ok;
let m=db.runCommand({isMaster:1}).ok;
let b=db.runCommand({buildInfo:1}).ok;
print(p+","+h+","+m+","+b);
')
[ "$R" = "1,1,1,1" ] && pass "6.1 Wire protocol (ping/hello/isMaster/buildInfo)" || fail "6.1 Wire protocol" "$R"

# --- CRUD ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.crud.drop();
db.crud.insertOne({name:"alice",age:30});
db.crud.insertMany([{name:"bob",age:25},{name:"charlie",age:35},{name:"diana",age:28}]);
let count = db.crud.countDocuments();
let one = db.crud.findOne({name:"alice"});
db.crud.updateOne({name:"alice"},{$set:{age:31}});
let updated = db.crud.findOne({name:"alice"});
db.crud.updateMany({age:{$lt:30}},{$set:{young:true}});
let youngCount = db.crud.countDocuments({young:true});
db.crud.deleteOne({name:"charlie"});
let afterDel = db.crud.countDocuments();
db.crud.deleteMany({age:{$lt:30}});
let final_count = db.crud.countDocuments();
print(count+","+one.name+","+updated.age+","+youngCount+","+afterDel+","+final_count);
')
[ "$R" = "4,alice,31,2,3,1" ] && pass "4.1 CRUD operations" || fail "4.1 CRUD" "$R"

# --- Aggregation ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.agg.drop();
db.agg.insertMany([
  {dept:"eng",salary:100},{dept:"eng",salary:120},{dept:"eng",salary:90},
  {dept:"sales",salary:80},{dept:"sales",salary:95},{dept:"hr",salary:70}
]);
let res = db.agg.aggregate([
  {$group:{_id:"$dept",total:{$sum:"$salary"},count:{$sum:1}}},
  {$sort:{_id:1}}
]).toArray();
print(res.map(r=>r._id+":"+r.total+":"+r.count).join("|"));
')
[ "$R" = "eng:310:3|hr:70:1|sales:175:2" ] && pass "4.2 Aggregation pipeline" || fail "4.2 Aggregation" "$R"

# --- Indexes ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.idx.drop();
db.idx.insertMany([{a:1,b:"x"},{a:2,b:"y"},{a:3,b:"z"}]);
db.idx.createIndex({a:1});
db.idx.createIndex({a:1,b:1});
db.idx.createIndex({b:1},{unique:true});
let cnt = db.idx.getIndexes().length;
db.idx.dropIndex("a_1");
let after = db.idx.getIndexes().length;
print(cnt+","+after);
')
[ "$R" = "4,3" ] && pass "4.3 Index operations (create/get/drop)" || fail "4.3 Index ops" "$R"

# --- Collection management ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb");
db.createCollection("coll_mgmt");
let l1 = db.getCollectionNames().filter(c=>c==="coll_mgmt").length;
db.coll_mgmt.drop();
let l2 = db.getCollectionNames().filter(c=>c==="coll_mgmt").length;
print(l1+","+l2);
')
[ "$R" = "1,0" ] && pass "4.4 Collection management" || fail "4.4 Collection mgmt" "$R"

# --- Database operations ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("tempdb");
db.createCollection("test_coll"); db.test_coll.insertOne({x:1});
let dbs = db.adminCommand({listDatabases:1}).databases.map(d=>d.name);
let exists = dbs.includes("tempdb");
db.dropDatabase();
let dbs2 = db.adminCommand({listDatabases:1}).databases.map(d=>d.name);
let gone = !dbs2.includes("tempdb");
print(exists+","+gone);
')
[ "$R" = "true,true" ] && pass "4.5 Database operations" || fail "4.5 Database ops" "$R"

# --- Bulk write ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.bulk.drop();
let res = db.bulk.bulkWrite([
  {insertOne:{document:{x:1}}},{insertOne:{document:{x:2}}},{insertOne:{document:{x:3}}},
  {updateOne:{filter:{x:1},update:{$set:{y:10}}}},
  {deleteOne:{filter:{x:3}}}
]);
print(res.insertedCount+","+res.modifiedCount+","+res.deletedCount+","+db.bulk.countDocuments()+","+db.bulk.countDocuments({y:10}));
')
[ "$R" = "3,1,1,2,1" ] && pass "4.6 Bulk write" || fail "4.6 Bulk write" "$R"

# --- findAndModify ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.fam.drop();
db.fam.insertMany([{name:"a",v:1},{name:"b",v:2},{name:"c",v:3}]);
let r1 = db.fam.findOneAndUpdate({name:"a"},{$set:{v:10}},{returnDocument:"after"});
let r2 = db.fam.findOneAndDelete({name:"c"});
print(r1.v+","+r2.v+","+db.fam.countDocuments());
')
[ "$R" = "10,3,2" ] && pass "4.7 findOneAndUpdate/Delete" || fail "4.7 findAndModify" "$R"

# --- Distinct / count ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.dc.drop();
db.dc.insertMany([{cat:"a",v:1},{cat:"b",v:2},{cat:"a",v:3},{cat:"c",v:4},{cat:"b",v:5}]);
print(db.dc.distinct("cat").sort().join(",")+","+db.dc.countDocuments({cat:"a"})+","+db.dc.estimatedDocumentCount());
')
[ "$R" = "a,b,c,2,5" ] && pass "4.8 Distinct and count" || fail "4.8 Distinct/count" "$R"

# --- Geospatial ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.geo.drop();
db.geo.insertMany([
  {name:"nyc",loc:{type:"Point",coordinates:[-74.006,40.7128]}},
  {name:"la",loc:{type:"Point",coordinates:[-118.2437,34.0522]}},
  {name:"chicago",loc:{type:"Point",coordinates:[-87.6298,41.8781]}},
  {name:"london",loc:{type:"Point",coordinates:[-0.1278,51.5074]}}
]);
db.geo.createIndex({loc:"2dsphere"});
let nearRes = db.geo.find({loc:{$near:{$geometry:{type:"Point",coordinates:[-74,40.7]},$maxDistance:200000}}}).toArray();
print(nearRes.map(d=>d.name).join(","));
')
echo "$R" | grep -q "nyc" && pass "4.9 Geospatial queries" || fail "4.9 Geospatial" "$R"

# --- Text search ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.txt.drop();
db.txt.insertMany([
  {title:"MongoDB is great",body:"document database"},
  {title:"PostgreSQL rocks",body:"relational database"},
  {title:"DocumentDB combines both",body:"MongoDB compatible on PostgreSQL"}
]);
db.txt.createIndex({title:"text",body:"text"});
let results = db.txt.find({$text:{$search:"MongoDB"}}).toArray();
print(results.length+","+results.map(r=>r.title).sort().join("|"));
')
echo "$R" | grep -qE "^[23],.*MongoDB" && pass "4.10 Text search" || fail "4.10 Text search" "$R"

# --- Transactions ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.txn.drop();
db.txn.insertOne({name:"initial",v:0});
let session = db.getMongo().startSession();
let coll = session.getDatabase("testdb").getCollection("txn");
session.startTransaction();
coll.updateOne({name:"initial"},{$set:{v:1}});
coll.insertOne({name:"txn_added",v:2});
session.commitTransaction();
session.endSession();
let docs = db.txn.find({}).sort({v:1}).toArray();
print(docs.map(d=>d.name+":"+d.v).join(","));
')
[ "$R" = "initial:1,txn_added:2" ] && pass "4.11 Transaction commit" || fail "4.11 Transaction" "$R"

R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.txn_abort.drop();
db.txn_abort.insertOne({name:"keep",v:1});
let session = db.getMongo().startSession();
let coll = session.getDatabase("testdb").getCollection("txn_abort");
session.startTransaction();
coll.insertOne({name:"discard",v:2});
session.abortTransaction();
session.endSession();
print(db.txn_abort.countDocuments());
')
[ "$R" = "1" ] && pass "4.12 Transaction abort" || fail "4.12 Transaction abort" "$R"

# --- Data type fidelity ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.types.drop();
db.types.insertOne({
  str:"hello", num_int:NumberInt(42), num_long:NumberLong("9876543210"),
  num_double:3.14, bool_t:true, bool_f:false, null_v:null,
  date_v:new Date("2024-01-15T00:00:00Z"),
  arr:[1,"two",{three:3}], nested:{a:{b:{c:"deep"}}}, regex:/^test$/i
});
let doc = db.types.findOne();
let ok = typeof doc.str==="string" && doc.num_int===42 && doc.num_double===3.14
  && doc.bool_t===true && doc.bool_f===false && doc.null_v===null
  && doc.arr.length===3 && doc.nested.a.b.c==="deep";
print(ok);
')
[ "$R" = "true" ] && pass "4.13 Data type fidelity" || fail "4.13 Data types" "$R"

# --- Cursor pagination ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.cursor.drop();
let bulk=[]; for(let i=0;i<100;i++) bulk.push({idx:i,data:"x".repeat(100)});
db.cursor.insertMany(bulk);
let cursor = db.cursor.find().batchSize(10);
let total=0; while(cursor.hasNext()){cursor.next();total++;}
print(total);
')
[ "$R" = "100" ] && pass "4.14 Cursor pagination (100 docs)" || fail "4.14 Cursors" "$R"

# --- Sample data ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("sampledb");
print(db.users.countDocuments()+","+db.products.countDocuments()+","+db.orders.countDocuments()+","+db.analytics.countDocuments());
')
[ "$R" = "5,5,4,2" ] && pass "5.1 Sample data counts" || fail "5.1 Sample data" "$R"

R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("sampledb");
let s=db.users.countDocuments({city:"Seattle"});
let e=db.products.countDocuments({category:"Electronics"});
let d=db.orders.countDocuments({status:"delivered"});
let p=db.users.countDocuments({tags:"premium"});
print(s+","+e+","+d+","+p);
')
[ "$R" = "1,2,1,3" ] && pass "5.2 Sample data queries" || fail "5.2 Sample queries" "$R"

# --- System integrity ---
R=$(docker exec "$MAIN_CONTAINER" id postgres 2>/dev/null)
echo "$R" | grep -q "uid=105.*gid=103" && pass "7.1 Postgres UID/GID (105:103)" || fail "7.1 UID/GID" "$R"

R=$(docker exec "$MAIN_CONTAINER" bash -c "PGPASSWORD=$PASSWORD psql -h localhost -p 9712 -U $USERNAME -d postgres -t -A -c \"SELECT extname FROM pg_extension ORDER BY extname;\"" 2>/dev/null | grep -v "^SET" | tr '\n' ',')
for ext in documentdb documentdb_core pg_cron; do
    echo "$R" | grep -q "$ext" && pass "7.2 Extension: $ext" || fail "7.2 Extension: $ext" "exts=$R"
done

R=$(docker exec "$MAIN_CONTAINER" find /usr/lib/postgresql -name "pg_documentdb*.so" 2>/dev/null | wc -l)
[ "$R" -ge 2 ] && pass "7.3 Shared libraries ($R .so files)" || fail "7.3 Shared libs" "$R"

R=$(docker exec "$MAIN_CONTAINER" pgrep -f documentdb_gateway 2>/dev/null | head -1)
[ -n "$R" ] && pass "7.4 Gateway binary running" || fail "7.4 Gateway" "not running"

R=$(docker exec "$MAIN_CONTAINER" mongosh --version 2>/dev/null | head -1)
echo "$R" | grep -qE '^[0-9]+\.' && pass "7.5 mongosh works (v$R)" || fail "7.5 mongosh" "$R"

for tool in bash psql pg_isready pg_dump pg_restore nc; do
    R=$(docker exec "$MAIN_CONTAINER" which "$tool" 2>/dev/null || echo "")
    [ -n "$R" ] && pass "7.6 Tool: $tool" || fail "7.6 Tool: $tool" "missing"
done

for path in /var/log/documentdb /data; do
    docker exec "$MAIN_CONTAINER" test -d "$path" 2>/dev/null && pass "7.7 Dir: $path" || fail "7.7 Dir: $path" "missing"
done

docker exec "$MAIN_CONTAINER" test -f /home/documentdb/gateway/pg_documentdb_gw/SetupConfiguration.json 2>/dev/null \
    && pass "7.8 SetupConfiguration.json" || fail "7.8 Config" "missing"

# --- Logging ---
docker logs "$MAIN_CONTAINER" > /tmp/e2e_logs_$$.txt 2>&1
for pat in "Starting PostgreSQL" "DocumentDB is ready" "POSTGRES"; do
    grep -q "$pat" /tmp/e2e_logs_$$.txt && pass "9.1 Log: $pat" || fail "9.1 Log: $pat" "missing"
done
rm -f /tmp/e2e_logs_$$.txt

R=$(docker exec "$MAIN_CONTAINER" ls /var/log/documentdb/ 2>/dev/null | wc -l)
[ "$R" -ge 1 ] && pass "9.2 Log directory populated" || fail "9.2 Log dir" "empty"

# --- Error handling ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.errlog.drop();
db.errlog.createIndex({uid:1},{unique:true});
db.errlog.insertOne({uid:1});
try{db.errlog.insertOne({uid:1});print("no_error")}catch(e){print("dup_key_caught")}
')
[ "$R" = "dup_key_caught" ] && pass "9.3 Duplicate key error caught" || fail "9.3 Error" "$R"

# --- Edge cases ---
echo ""
echo "Testing concurrent connections..."
CONN_DIR="/tmp/e2e_conn_$$"
rm -rf "$CONN_DIR"; mkdir -p "$CONN_DIR"
for i in $(seq 1 5); do
    (ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" "use('testdb');db.cc_$i.drop();db.cc_$i.insertOne({t:$i});print(db.cc_$i.countDocuments())" > "$CONN_DIR/$i") &
done
wait
OK=0
for i in $(seq 1 5); do [ "$(cat "$CONN_DIR/$i" 2>/dev/null)" = "1" ] && OK=$((OK+1)); done
rm -rf "$CONN_DIR"
[ $OK -eq 5 ] && pass "10.1 Concurrent connections (5/5)" || fail "10.1 Concurrent" "$OK/5"

R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.uni.drop();
db.uni.insertOne({cn:"你好世界",jp:"こんにちは",em:"🚀💻🎉"});
let d=db.uni.findOne();
print(d.cn==="你好世界"&&d.em==="🚀💻🎉");
')
[ "$R" = "true" ] && pass "10.2 Unicode / emoji handling" || fail "10.2 Unicode" "$R"

R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("testdb"); db.emp.drop(); db.createCollection("emp");
let f=db.emp.find().toArray().length;
let c=db.emp.countDocuments();
let d=db.emp.distinct("field").length;
print(f+","+c+","+d);
')
[ "$R" = "0,0,0" ] && pass "10.3 Empty collection operations" || fail "10.3 Empty coll" "$R"

# --- Performance smoke ---
R=$(ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" '
use("perfdb"); db.perf.drop();
let docs=[]; for(let i=0;i<1000;i++) docs.push({idx:i,name:"user_"+i,age:20+(i%50)});
let t0=Date.now(); db.perf.insertMany(docs); let ti=Date.now()-t0;
t0=Date.now(); db.perf.createIndex({age:1,name:1}); let tx=Date.now()-t0;
t0=Date.now(); for(let i=0;i<100;i++) db.perf.find({age:{$gte:30,$lt:40}}).toArray(); let tq=Date.now()-t0;
t0=Date.now(); for(let i=0;i<100;i++) db.perf.updateOne({idx:i},{$set:{updated:true}}); let tu=Date.now()-t0;
t0=Date.now(); db.perf.aggregate([{$group:{_id:"$age",c:{$sum:1}}},{$sort:{c:-1}}]).toArray(); let ta=Date.now()-t0;
print("INSERT:"+ti+"ms INDEX:"+tx+"ms QUERY:"+tq+"ms UPDATE:"+tu+"ms AGG:"+ta+"ms");
')
echo "  Performance: $R"
echo "$R" | grep -q "INSERT:" && pass "8.1 Performance smoke test" || fail "8.1 Performance" "$R"

# Cleanup test dbs
ms "$MAIN_PORT" "$USERNAME" "$PASSWORD" 'use("testdb");db.dropDatabase();use("perfdb");db.dropDatabase()' >/dev/null 2>&1 || true

# Cleanup main container
cleanup_container "$MAIN_CONTAINER"

# ============================================================
# PHASE 2: CLI flags, error handling, lifecycle
# ============================================================

echo ""
echo "=============================================="
echo "  PHASE 2: CLI Flags, Errors, Lifecycle"
echo "=============================================="

# --- 2.2 --skip-init-data ---
C="e2e-skip-$$"; P=$((BASE_PORT + 1))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data >/dev/null
if wait_ready "$C"; then
    R=$(ms "$P" "$USERNAME" "$PASSWORD" 'print(db.adminCommand({listDatabases:1}).databases.map(d=>d.name).filter(n=>n==="sampledb").length)')
    [ "$R" = "0" ] && pass "2.2 --skip-init-data" || fail "2.2 --skip-init-data" "sampledb=$R"
else
    fail "2.2 --skip-init-data" "not ready"
fi
cleanup_container "$C"

# --- 2.4 --documentdb-port ---
C="e2e-port-$$"; P=$((BASE_PORT + 2))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:27017" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data --documentdb-port 27017 >/dev/null
if wait_ready "$C"; then
    R=$(ms "$P" "$USERNAME" "$PASSWORD" 'print(db.runCommand({ping:1}).ok)')
    [ "$R" = "1" ] && pass "2.4 --documentdb-port 27017" || fail "2.4 Custom port" "$R"
else
    fail "2.4 --documentdb-port" "not ready"
fi
cleanup_container "$C"

# --- 2.6 --log-level ---
C="e2e-log-$$"; P=$((BASE_PORT + 3))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data --log-level debug >/dev/null
if wait_ready "$C"; then
    pass "2.6 --log-level debug (accepted)"
else
    fail "2.6 --log-level debug" "not ready"
fi
cleanup_container "$C"

# --- 2.11 --disable-extended-rum ---
C="e2e-rum-$$"; P=$((BASE_PORT + 4))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data --disable-extended-rum >/dev/null
if wait_ready "$C"; then
    R=$(ms "$P" "$USERNAME" "$PASSWORD" 'use("testdb");db.t.drop();db.t.insertOne({x:1});print(db.t.countDocuments())')
    [ "$R" = "1" ] && pass "2.11 --disable-extended-rum (CRUD works)" || fail "2.11 --disable-extended-rum" "$R"
else
    fail "2.11 --disable-extended-rum" "not ready"
fi
cleanup_container "$C"

# --- 2.9 --allow-external-connections ---
C="e2e-ext-$$"; P=$((BASE_PORT + 5))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data --allow-external-connections true >/dev/null
if wait_ready "$C"; then
    R=$(docker exec "$C" bash -c "cat /data/pg_hba.conf" 2>/dev/null | grep -c "0.0.0.0/0" || echo 0)
    [ "$R" -ge 1 ] && pass "2.9 --allow-external-connections" || fail "2.9 External conn" "hba=$R"
else
    fail "2.9 --allow-external-connections" "not ready"
fi
cleanup_container "$C"

# --- 2.13 Environment variable overrides ---
C="e2e-env-$$"; P=$((BASE_PORT + 6))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" \
    -e USERNAME=envuser -e PASSWORD=EnvPass123 -e SKIP_INIT_DATA=true -e LOG_LEVEL=warn \
    "$IMAGE_NAME" >/dev/null
if wait_ready "$C"; then
    R=$(ms "$P" "envuser" "EnvPass123" 'print(db.runCommand({ping:1}).ok)')
    [ "$R" = "1" ] && pass "2.13 Env var overrides" || fail "2.13 Env vars" "$R"
else
    fail "2.13 Env var overrides" "not ready"
fi
cleanup_container "$C"

# --- Error handling ---
echo ""
echo "--- Error handling tests ---"

# 3.2 Invalid port
C="e2e-badport-$$"
cleanup_container "$C"
docker run -d --name "$C" "$IMAGE_NAME" --password Pass123 --documentdb-port abc >/dev/null 2>&1 || true
sleep 5
EXIT=$(docker inspect "$C" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
[ "$EXIT" != "0" ] && pass "3.2 Invalid port rejected" || fail "3.2 Invalid port" "exit=$EXIT"
cleanup_container "$C"

# 3.3 Mismatched cert/key
C="e2e-cert-$$"
cleanup_container "$C"
docker run -d --name "$C" "$IMAGE_NAME" --password Pass123 --cert-path /nonexist/cert.pem >/dev/null 2>&1 || true
sleep 5
EXIT=$(docker inspect "$C" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
[ "$EXIT" != "0" ] && pass "3.3 Mismatched cert/key rejected" || fail "3.3 Cert/key" "exit=$EXIT"
cleanup_container "$C"

# 3.4 Invalid log level
C="e2e-badlog-$$"
cleanup_container "$C"
docker run -d --name "$C" "$IMAGE_NAME" --password Pass123 --log-level banana >/dev/null 2>&1 || true
sleep 5
EXIT=$(docker inspect "$C" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
[ "$EXIT" != "0" ] && pass "3.4 Invalid log level rejected" || fail "3.4 Log level" "exit=$EXIT"
cleanup_container "$C"

# 3.6 Unknown flag
C="e2e-badflag-$$"
cleanup_container "$C"
docker run -d --name "$C" "$IMAGE_NAME" --password Pass123 --nonexistent-flag >/dev/null 2>&1 || true
sleep 5
EXIT=$(docker inspect "$C" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
[ "$EXIT" != "0" ] && pass "3.6 Unknown flag rejected" || fail "3.6 Unknown flag" "exit=$EXIT"
cleanup_container "$C"

# --- Lifecycle: Graceful shutdown ---
echo ""
echo "--- Lifecycle tests ---"

C="e2e-shutdown-$$"; P=$((BASE_PORT + 7))
cleanup_container "$C"
docker run -dt --name "$C" -p "${P}:10260" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data >/dev/null
if wait_ready "$C"; then
    ms "$P" "$USERNAME" "$PASSWORD" 'use("shutdowndb"); db.test.insertOne({x:1})' >/dev/null 2>&1 || true
    docker stop "$C" >/dev/null 2>&1
    docker logs "$C" > /tmp/shutdown_$$.txt 2>&1
    if grep -qiE "segfault|SIGSEGV" /tmp/shutdown_$$.txt; then
        fail "1.3 Graceful shutdown" "crash detected"
    else
        pass "1.3 Graceful shutdown (no crash)"
    fi
    rm -f /tmp/shutdown_$$.txt
else
    fail "1.3 Graceful shutdown" "not ready"
fi
cleanup_container "$C"

# --- Lifecycle: Data persistence ---
C="e2e-persist-$$"; P=$((BASE_PORT + 8))
VOL="/tmp/e2e-persist-$$"
rm -rf "$VOL" && mkdir -p "$VOL"
cleanup_container "$C"

docker run -dt --name "$C" -p "${P}:10260" -v "${VOL}:/data" "$IMAGE_NAME" \
    --username "$USERNAME" --password "$PASSWORD" --skip-init-data >/dev/null
if wait_ready "$C"; then
    ms "$P" "$USERNAME" "$PASSWORD" 'use("persistdb"); db.test.insertOne({key:"survive",val:42})' >/dev/null 2>&1 || true
    docker stop "$C" >/dev/null 2>&1
    docker rm "$C" >/dev/null 2>&1

    docker run -dt --name "$C" -p "${P}:10260" -v "${VOL}:/data" "$IMAGE_NAME" \
        --username "$USERNAME" --password "$PASSWORD" --skip-init-data >/dev/null
    if wait_ready "$C"; then
        R=$(ms "$P" "$USERNAME" "$PASSWORD" 'use("persistdb"); let d=db.test.findOne({key:"survive"}); print(d ? d.val : "missing")')
        [ "$R" = "42" ] && pass "1.4 Data persistence across restart" || fail "1.4 Persistence" "$R"
    else
        fail "1.4 Data persistence (restart)" "not ready"
    fi
else
    fail "1.4 Data persistence (first run)" "not ready"
fi
cleanup_container "$C"
rm -rf "$VOL"

# ============================================================
# PHASE 3: Custom init data
# ============================================================

echo ""
echo "=============================================="
echo "  PHASE 3: Custom Init Data"
echo "=============================================="

INIT_DATA_DIR="$SCRIPT_DIR/test-init-data"
if [ -d "$INIT_DATA_DIR" ]; then
    C="e2e-initdata-$$"; P=$((BASE_PORT + 9))
    cleanup_container "$C"
    docker run -dt --name "$C" -p "${P}:10260" \
        -v "${INIT_DATA_DIR}:/init_doc_db.d" \
        "$IMAGE_NAME" --username "$USERNAME" --password "$PASSWORD" \
        --init-data-path /init_doc_db.d >/dev/null

    if wait_ready "$C" 120; then
        # Wait for init to complete
        sleep 10
        R=$(ms "$P" "$USERNAME" "$PASSWORD" '
use("test");
let u=db.users.countDocuments();
let p=db.products.countDocuments();
let o=db.orders.countDocuments();
print(u+","+p+","+o);
')
        [ "$R" = "4,4,4" ] && pass "3.5 Custom init-data-path (4,4,4)" || fail "3.5 Custom init" "$R"
    else
        fail "3.5 Custom init-data-path" "not ready"
    fi
    cleanup_container "$C"
else
    echo "⏭️  SKIP: Custom init data dir not found at $INIT_DATA_DIR"
fi

# ============================================================
# SUMMARY
# ============================================================

echo ""
echo "=============================================="
echo "  E2E TEST RESULTS"
echo "=============================================="
echo "  Total:   $TOTAL_COUNT"
echo "  ✅ Pass:  $PASS_COUNT"
echo "  ❌ Fail:  $FAIL_COUNT"
echo "=============================================="
echo ""

for r in "${RESULTS[@]}"; do
    echo "  $r"
done

echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    echo "❌ $FAIL_COUNT test(s) failed"
    exit 1
else
    echo "✅ All $PASS_COUNT tests passed"
    exit 0
fi
