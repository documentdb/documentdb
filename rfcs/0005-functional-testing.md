---
rfc: 0005
title: "End-to-End Functional Testing Framework for DocumentDB"
status: Draft
owner: "@nitinahuja89"
issue: "https://github.com/documentdb/documentdb/issues/367"
---

# RFC-0005: End-to-End Functional Testing Framework for DocumentDB

## Problem

DocumentDB currently lacks a systematic end-to-end functional testing framework that validates correctness against DocumentDB specifications.

**Existing test coverage:**
- Component-level functionality (pg_documentdb regression tests)
- Wire protocol compatibility (pg_documentdb_gw integration tests)
- Core BSON operations (pg_documentdb_core tests)

**The gap this RFC targets:**
End-to-end functional testing that validates complete user workflows against DocumentDB specifications. This means testing from the user's perspective - when they send a query or command, do they get the expected result as defined by DocumentDB specifications?

**Example gap:** We have aggregation tests, but not systematic specification-informed validation that covers all aggregation operators with defined expected outputs across all supported data types and scenarios.

**Who is impacted:**
- Contributors who cannot easily validate that their changes don't break existing functionality
- Users who may encounter regressions due to insufficient testing coverage
- Product teams who lack visibility into functional correctness metrics

**Current consequences:**
- **Limited Confidence**: Developers cannot easily validate end-to-end functionality, increasing regression risk
- **Functional Gaps**: No systematic way to measure and track functional correctness against DocumentDB specifications  
- **Manual Testing Burden**: Contributors rely on manual testing for validation, slowing development velocity

**Current workarounds:**
- Manual testing by contributors before submitting PRs
- Ad-hoc end-to-end functional testing
- Reliance on existing tests that don't cover end-to-end specification validation
- Post-deployment discovery of functional issues

**Success criteria:**
- Users are able to run all functional tests against locally hosted or remotely hosted DocumentDB with a single command and no setup involved (DocumentDB setup and environment provisioning is outside the scope - the framework assumes a running DocumentDB instance and takes a connection string as input)
- Contributors can simply add new test files and it would automatically get picked up to be run as part of the functional test suite
- Contributors/ users should get a list of all the test failures together (the test execution should not abort on a single failed test)
- Contributors get easy to understand messages/logs for each failing test that points to the exact cause for the failure
- Contributors should get failed tests categorized by feature tags to make it easy to understand which features have issues
- Result comparison: Compare test results across different engines or engine versions, generate compatibility reports with regression/improvement analysis, and provide metrics at multiple granularity levels with machine-readable output for CI integration

**Non-goals:**
- Performance/load/stress testing
- Unit testing improvements
- Security testing
- Migration testing from other databases

---

## Relationship to RFC-0002

This RFC implements **Layers C and D** from RFC-0002's unified testing framework:
- **Layer C**: End-to-end functional testing with specification-informed approach
- **Layer D**: Compatibility testing across MongoDB implementations

The functional testing framework described here is designed to integrate with the unified testing infrastructure proposed in RFC-0002. Specific integration details and orchestration mechanisms will be addressed in RFC-0002 or its implementation updates.

---

## Approach

The proposed solution is an end-to-end functional testing framework that uses **specification-informed testing** to validate DocumentDB functionality.

**Self-contained Test Suite**: Tests with explicit specifications that define expected behavior for DocumentDB features. Tests can be executed against any engine implementing the MongoDB wire protocol.

**Why this approach is preferable:**

- **Specification-informed**: Tests define explicit expectations for DocumentDB behavior
- **Self-contained**: Each test includes all necessary setup and assertions
- **Future-proof**: Has the ability to support DocumentDB-unique features and functionality
- **Leverages pytest**: Uses proven testing infrastructure

**Key benefits:**
- Automated functional correctness validation using pytest
- Easy test authoring for contributors using familiar pytest
- Integration with existing development workflows (local, CI/CD)
- Clear failure reporting and debugging capabilities
- Systematic test organization using pytest markers

**Key tradeoffs:**
- Initial development investment for the testing infrastructure vs long-term development velocity gains
- Test execution time vs comprehensive coverage

**Alignment with existing architecture:**
- Integrates with current CI/CD infrastructure (GitHub Actions)
- Supports both local execution and execution in remote environments (via a Docker image)
- Complements existing unit testing framework

---

## Detailed Design

### Functional Components

The end-to-end functional testing framework leverages pytest as the core testing infrastructure and adds a separate component to process the test results.

**1. pytest Framework:**
- **Purpose**: Handles test discovery, execution, parallelization, and reporting
- **Responsibilities**:
  - Test discovery and filtering using pytest markers
  - Parallel test execution using pytest-xdist (multiprocessing)
  - Single-engine test execution with separate runs per engine
  - Fixture-based setup and cleanup
  - Multiple output formats via plugins

**2. Result Analyzer Tool:**
- **Purpose**: Processes pytest output with metadata to categorize and analyze test results
- **Responsibilities**:
  - Analyzes pass/fail results for DocumentDB functionality
  - Generates metrics by feature tags
  - Categorizes test outcomes (PASS, FAIL, INFRA_ERROR)
  - Stores detailed test results including failure details and metadata
  - Creates dashboards and reports
- **Benefits of Separate Tool**:
  - Framework agnostic: Can analyze results from any test runner that produces compatible output format
  - Batch processing: Analyze multiple test runs for trend analysis
  - Flexible deployment: Can run on different infrastructure than test execution

**3. Result Comparison Tool:**
- **Purpose**: Compare results from separate test executions
- **Responsibilities**:
  - Load and parse stored test results from different runs
  - Compare test outcomes (status and failure details) between runs
  - Generate comparison reports showing differences
  - Support comparison across different engines, versions, or time periods

**4. Test Suites:**
- **DocumentDB Functional Test Suite**: 
  - Self-contained tests with explicit specifications for DocumentDB functionality
  - Multi-dimensional tagging system using pytest markers
  - Designed for easy test authoring by contributors
  - Supports DocumentDB unique features and capabilities

### Functional Test Tagging System

The following two-dimensional tagging strategy is used for organizing and filtering tests using pytest markers:

**Horizontal Tags (API Operations):**
- `find`, `insert`, `update`, `delete`, `aggregate`, `index`, `admin`, `collection_mgmt`

**Vertical Tags (Cross-cutting Features):**
- `rbac`, `decimal128`, `collation`, `transactions`, `geospatial`, `text_search`, `validation`, `ttl`

**Additional Tags:**
- `smoke`: Quick feature detection tests to determine if functionality is implemented

**Example Test Tags:**
- Find operation using decimal128 with collation: `@pytest.mark.find @pytest.mark.decimal128 @pytest.mark.collation`
- Find with RBAC: `@pytest.mark.find @pytest.mark.rbac`
- TTL Index creation: `@pytest.mark.index @pytest.mark.ttl`
- Smoke test for aggregation: `@pytest.mark.aggregate @pytest.mark.smoke`

The tags are used for grouping, organizing and filtering tests. They allow users to run tests for specific features and enable grouping when reporting test results. All tests use the same failure types (PASS, FAIL, INFRA_ERROR) regardless of their tags.

### Running the Tests

The functional testing framework supports multiple execution contexts:

**1. Test Development (functional-tests repository):**
For test authors developing new tests in the functional-tests repository:

```bash
git clone https://github.com/documentdb/functional-tests
cd functional-tests

# Set up Python environment (recommended)
pyenv install 3.11.0  # or version specified in .python-version
pyenv local 3.11.0
pip install -r requirements.txt

# Alternative: Direct pip install (if pyenv not available)
# pip install -r requirements.txt

# Run tests during development
pytest --connection-string mongodb://localhost:27017 --engine-name documentdb
```

**2. Docker Execution:**
Tests run via Docker image with all dependencies included. Published as `documentdb/functional-tests`.

```bash
# Generic execution
docker run documentdb/functional-tests:v1.2.3 \
  --connection-string <connection-string> \
  --engine-name <engine-name> \
  [--test-config <config-file>] \
  [--overrides-dir <overrides-dir>] \
  [--results-output <output-dir>]

# Examples:
# DocumentDB (with configuration)
docker run documentdb/functional-tests:v1.2.3 \
  --connection-string mongodb://localhost:27017 \
  --engine-name documentdb \
  --test-config ./test-config/test-expectations.yaml \
  --overrides-dir ./test-config/overrides/ \
  --results-output ./test-results/

# AWS DocumentDB
docker run documentdb/functional-tests \
  --connection-string mongodb://cluster.docdb.amazonaws.com:27017 \
  --engine-name amazon-documentdb

# Azure Cosmos DB (MongoDB API)
docker run documentdb/functional-tests \
  --connection-string mongodb://myaccount.mongo.cosmos.azure.com:27017 \
  --engine-name microsoft-documentdb

# MongoDB
docker run documentdb/functional-tests \
  --connection-string mongodb://mongo.example.com:27017 \
  --engine-name mongodb
```

*Benefits:*
- **Flexibility**: Contributors can run and debug tests locally
- **Portability**: Docker image provides consistent environment for testing in remote environments
- **CI/CD Integration**: Works with existing GitHub Actions workflows

### Test Execution Flow

```
pytest:
  → Parse configuration (connection-string, engine-name, tags, parallelism)
  → Discover and filter tests based on markers
  → Execute tests in parallel using pytest-xdist (multiprocessing)
      For each test:
        → Generate unique namespace using test name
        → Setup using pytest fixtures
        → Run test against specified engine
        → Cleanup via fixture teardown
        → Collect results (pass/fail with detailed failure information)
  → Generate pytest output (JSON, JUnit XML via plugins)
                    ↓
Result Analyzer Tool:
  → Parse pytest output with metadata
  → Categorize results by failure type:
    - PASS (test succeeded)
    - FAIL (assertion failed)
    - UNSUPPORTED (feature not implemented)
    - INFRA_ERROR (infrastructure issue)
  → Store detailed results with failure details and metadata
  → Calculate metrics by tags
  → Create reports and dashboards
  → Generate stored analysis results file
                    ↓
Optional Comparison Flow:
compare-results tool:
  → Load two stored analysis result files
  → Compare test outcomes and failure details
  → Generate comparison report showing:
    - Status changes between runs
    - Failure detail differences
    - New failures/passes
    - Summary statistics
```

### Implementation Details

#### pytest Framework

**Configuration Management:**
- Configuration provided via command line arguments and optional YAML files
- Configuration parameters:
  - `connection-string`: Database connection string (e.g., `--connection-string mongodb://localhost:27017`)
  - `engine-name`: Optional engine identifier for metadata (e.g., `--engine-name documentdb`). Stored as metadata and used by Result Analyzer Tool and Result Comparison Tool to provide clear comparison reports
  - `tags`: pytest marker filtering (e.g., `-m "find and rbac"`)
  - `parallelism`: Number of concurrent processes via pytest-xdist (e.g., `-n 8`)
  - `output_format`: Report format (JSON via `--json-report`, JUnit XML via `--junitxml`)
  - `fail_fast`: Stop on first failure (`-x`)

**Test Discovery:**
- Uses pytest's built-in discovery for files matching `test_*.py`
- Leverages pytest markers for tagging and filtering
- No custom test registry needed - pytest handles metadata

**Single-Engine Execution:**
- Engine specified via command-line parameters (connection-string and engine-name)
- Each test run targets a single engine connection
- Multiple engines tested through separate executions

**Parallel Execution:**
- Uses pytest-xdist for multiprocessing-based parallelism (avoids Python GIL limitations)
- Automatic load balancing across worker processes
- No custom thread pool management needed

#### Test Run Metadata

**Metadata Capture:**
The pytest framework captures comprehensive execution metadata during test runs, including:
- Test suite context (version/commit hash, test selection criteria, total test count)
- Execution environment (timestamp, connection string, engine name, server version information)

**Metadata Flow:**
The Result Analyzer preserves and forwards all execution metadata from pytest output to ensure analysis results are self-contained with complete run context.

**Comparability Validation:**
The Result Comparison Tool validates run compatibility using the preserved metadata:
- Verifies runs use compatible test suite versions and selection criteria
- Warns when comparing incompatible runs and explains why comparison may not be meaningful
- Ensures comparison integrity through metadata validation

#### Test Organization

**Directory Structure:**
For large features like `find`, tests are split by sub-functionality: basic queries, query operators, logical operators, projections, sorting, cursors, etc. Each file contains focused test cases for that specific aspect.

```
functional-tests/
├── find/                        # Find operation tests
│   ├── test_basic_queries.py    # Simple find(), findOne()
│   ├── test_query_operators.py  # $eq, $ne, $gt, $lt, $in, etc.
│   ├── test_logical_operators.py # $and, $or, $not, $nor
│   ├── test_projections.py      # Field inclusion/exclusion
│   ├── test_sorting.py          # sort(), compound sorts
│   └── test_cursors.py          # Cursor behavior, iteration
├── aggregate/                   # Aggregation pipeline tests
│   ├── test_match_stage.py
│   ├── test_group_stage.py
│   └── test_pipeline_combinations.py
├── common/                      # Shared utilities
│   ├── conftest.py              # pytest fixtures
│   └── assertions.py            # Custom assertion helpers
└── config/
    └── pytest.ini              # pytest configuration
```

**File Naming Conventions:**
- Test files: `test_<feature>.py` (e.g., `test_basic_queries.py`, `test_rbac.py`)
- Test functions: `test_<scenario>` (e.g., `test_find_with_filter`, `test_rbac_read_permission`)
- Use snake_case for all method names following Python conventions

**Test Example:**

```python
import pytest
from pymongo import MongoClient

@pytest.fixture
def collection(request, database_client):
    """Create isolated collection for test"""
    collection = database_client.test_db[request.node.name]
    yield collection
    collection.drop()

@pytest.mark.documents([{"status": "active"}, {"status": "inactive"}])
@pytest.mark.find
@pytest.mark.rbac
def test_rbac_read_permission(collection):
    """Verify read-only user can query documents"""
    # Test defines explicit specification for DocumentDB behavior
    result = collection.find({"status": "active"})
    result_list = list(result)
    
    # Structured assertions - enables detailed failure analysis
    from common.assertions import assert_document_equals, assert_count_equals
    
    assert_count_equals(result_list, 1, "Expected to find exactly 1 active document")
    assert_document_equals(result_list[0], {"status": "active"}, ignore_fields=["_id"])
```

**Tagging Conventions:**
- Use pytest markers: `@pytest.mark.find`, `@pytest.mark.rbac`
- Combine horizontal and vertical tags: `@pytest.mark.find @pytest.mark.rbac @pytest.mark.decimal128`
- Required: At least one horizontal tag (API operation)
- Optional: Vertical tags for cross-cutting features
- Smoke tests: `@pytest.mark.smoke` for quick feature detection

**Structured Assertions:**
Tests use custom assertion helpers that capture detailed failure information:
- **assert_document_equals()**: Compares documents with structured actual vs expected data
- **assert_count_equals()**: Validates counts with clear expected vs actual values  
- **assert_query_result()**: Validates query results with detailed failure context
- All assertions capture location, actual values, and expected values for enhanced debugging and analysis


#### Result Analyzer Implementation

**Result Analysis:**
The Result Analyzer Tool processes pytest output with metadata to generate functionality metrics and store detailed results for historical comparison. Operates independently of test execution, allowing for flexible analysis workflows and integration with various CI/CD systems.

**Enhanced Result Storage:**
For each test execution, store comprehensive results including:
- Test status (PASS, FAIL, INFRA_ERROR)
- Structured failure details (error type, message, actual vs expected values, location)
- Execution metadata (timestamp, engine, version, environment)
- Test metadata (duration, tags, test name)

**Storage Format:**
```json
{
  "execution_metadata": {
    "timestamp": "2026-01-16T14:20:00Z",
    "engine": "documentdb",
    "version": "1.0.0",
    "environment": "local"
  },
  "tests": [
    {
      "name": "test_find_with_projection",
      "status": "FAIL",
      "failure_details": {
        "error_type": "AssertionError",
        "error_message": "Expected {'name': 'Alice'}, got {'name': 'Alice', '_id': ObjectId(...)}",
        "actual": {"name": "Alice", "_id": "ObjectId(...)"},
        "expected": {"name": "Alice"},
        "location": "test_find_projection.py:42"
      },
      "duration": 0.52,
      "tags": ["find", "projection"]
    }
  ]
}
```

**Test Outcome Classification:**
For each test, analyze the result:

1. **PASS**
   - Test assertions passed
   - Feature works as specified

2. **FAIL**
   - Test assertions failed
   - Feature does not work as specified

3. **INFRA_ERROR**
   - Infrastructure/connection issues
   - Test system problems

**Test Outcome Categorization:**
- **PASS**: Test succeeded, behavior matches specification
- **FAIL**: Feature behaves incorrectly (assertion failed)
- **INFRA_ERROR**: Infrastructure/environment problem (connection issues, test setup failures, etc.)

**Failure Categorization by Tags:**
Group test results by their pytest markers to identify patterns

- **By API Operation Tags**: Which operations have issues?
  - Example: "5 out of 20 `aggregate` tests failed"

- **By Feature Tags**: Which cross-cutting features have issues?
  - Example: "8 out of 12 `decimal128` tests failed"

**Metrics Calculation:**
- **Feature coverage**: Functionality validation across different DocumentDB features
- **Tag-level metrics**: Pass rate for each tag
- **Overall statistics**: Simple pass rate across all tests

#### Result Comparison Tool Implementation

**Comparison Capabilities:**
The Result Comparison Tool processes stored analysis results from the Result Analyzer Tool to identify compatibility differences and regressions between different engines or engine versions.

**Output and CI/CD Integration:**
- Human-readable compatibility reports (HTML/text)
- Formal output schema (JSON/XML) to enable reliable CI/CD integration, historical analysis, and automation workflows
- Metrics at multiple granularity levels: overall pass rates, tag-based metrics, individual test results

**Comparison Types:**
1. **Status Changes**: Tests that changed between PASS/FAIL/UNSUPPORTED/INFRA_ERROR (includes new failures, new passes, and other status transitions)
2. **Failure Detail Changes**: Tests that failed in both runs but with different error messages
3. **Consistent Results**: Tests with identical outcomes for validation

**Comparison Output:**

**Example 1: Cross-Engine Comparison (DocumentDB vs MongoDB)**
```
Compatibility Analysis:
- test_find_projection: PASS (MongoDB) → FAIL (DocumentDB)
  ❌ DocumentDB incompatibility detected
- test_aggregate_sum: FAIL (MongoDB) → PASS (DocumentDB)
  ✅ DocumentDB improvement over MongoDB
- test_decimal_precision: FAIL (MongoDB) → FAIL (DocumentDB)
  ⚠️  Both engines fail, but different errors:
    MongoDB: "Decimal overflow error"
    DocumentDB: "Unsupported decimal precision"

Summary:
- Total tests compared: 150
- DocumentDB compatibility: 85% (127/150 tests match MongoDB behavior)
- DocumentDB improvements: 3 tests work better than MongoDB
- DocumentDB gaps: 20 tests fail where MongoDB passes
- Different failure reasons: 2 tests
```

**Example 2: Same-Engine Comparison (DocumentDB v1.0 vs DocumentDB v1.1)**
```
Regression Analysis:
- test_find_projection: PASS → FAIL
  ❌ REGRESSION: New failure in v1.1
- test_new_feature: N/A → PASS
  ✅ NEW: Feature added in v1.1
- test_aggregate_sum: FAIL → PASS
  ✅ FIXED: Bug resolved in v1.1
- test_decimal_precision: FAIL → FAIL
  ⚠️  Still failing, but error changed:
    v1.0: "Decimal overflow error"
    v1.1: "Improved decimal validation error"

Summary:
- Total tests compared: 150
- Regressions: 2 tests (1.3%)
- Fixes: 5 tests (3.3%)
- New features: 3 tests (2.0%)
- Consistent results: 140 tests (93.3%)
- Overall change: +6 net improvement
```

**Report Generation:**

The framework generates multiple types of outputs for different consumption models

1. **JSON Report** (for programmatic access and automation):
   - Machine-readable format for CI/CD pipelines and automation scripts
   - Structured data with test outcomes and metrics by engine and tag
   - Brief error identification (error type only, not full details)

```json
{
  "summary": {
    "total_tests": 150,
    "passed": 140,
    "failed": 10,
    "pass_rate": 93.3
  },
  "by_tags": {
    "find": {"passed": 45, "failed": 5, "pass_rate": 90.0},
    "aggregate": {"passed": 30, "failed": 3, "pass_rate": 90.9}
  },
  "tests": [
    {
      "name": "test_find_with_filter",
      "status": "PASS",
      "duration": 0.52,
      "tags": ["find"]
    },
    {
      "name": "test_aggregate_decimal",
      "status": "FAIL",
      "duration": 0.41,
      "error_type": "AssertionError",
      "tags": ["aggregate", "decimal128"]
    }
  ]
}
```

2. **JUnit XML** (for GitHub Actions integration):
   - Standard test report format for CI/CD integration
   - Rich UI integration in GitHub Actions for PR reviews
   - Test results appear in "Checks" tab with failure details

3. **Dashboard** (for visual consumption):
   - Summary statistics with charts
   - Test results table with filtering by status/tags
   - Detailed failure information
   - Trend analysis using historical data

#### Integration with DocumentDB Repository

The functional testing framework integrates with the DocumentDB repository to enable automated testing in CI/CD pipelines while maintaining separation between test authoring and test execution.

**Architecture Overview:**
- **functional-tests repository**: Contains test suite source code, maintained separately for test authoring and development
- **documentdb repository**: Integrates and executes specific versions of the functional test suite, stores results and configuration

**Integration Options:**

**Option 1: Docker Integration (Recommended)**
```yaml
# .github/workflows/functional-tests.yml in documentdb repo
- name: Run Functional Tests
  run: |
    docker run documentdb/functional-tests:${{ env.TEST_VERSION }} \
      --connection-string ${{ secrets.DOCUMENTDB_URL }} \
      --test-config ./test-config/config.yaml \
      --results-output ./test-results/
```

**Option 2: Git Submodule Integration**
```bash
# In documentdb repo
git submodule add https://github.com/documentdb/functional-tests tests/functional-tests
git submodule update --init --recursive

# CI execution
cd tests/functional-tests
pip install -r requirements.txt
pytest --connection-string $DOCUMENTDB_URL --test-config ../../test-config/config.yaml
```

**Docker Integration Advantages (Recommended):**
- **Precise versioning**: Immutable test suite versions with exact reproducibility
- **Environment isolation**: No dependency conflicts or Python version issues
- **CI/CD simplicity**: Fast execution without build dependencies
- **Consistent environments**: Same container across development, CI, and production testing
- **Easy rollback**: Simple version tag changes for testing different test suite versions

**DocumentDB Repository Structure:**
```
documentdb/
├── .github/workflows/
│   └── functional-tests.yml     # CI workflow for test execution
├── test-config/
│   ├── test-version.txt         # Functional test suite version (e.g., "v1.2.3")
│   ├── test-expectations.yaml    # Tests expected to pass/fail for current DocumentDB version
│   └── overrides/               # DocumentDB-specific test behavior overrides
├── test-results/
│   └── current.json            # Latest test execution results
└── docs/
    └── functional-testing.md   # Documentation for contributors
```

#### CI/CD Integration and Expectation Validation

**Expectation-Based Validation:**
The DocumentDB repository uses explicit test expectations defined in configuration files to detect regressions:
- Test results are validated against expected passing/failing tests defined in YAML configuration
- Regressions are detected when tests expected to pass actually fail
- New functionality is validated when tests move from expected_failing to expected_passing
- This approach provides explicit, version-controlled expectations without baseline drift

#### DocumentDB Contributor Workflow

**Overview:**
DocumentDB contributors can control functional test execution through configuration files in their PRs, allowing them to specify test versions, expected results, and behavioral overrides.

**Contributor Capabilities:**

**1. Update Test Suite Version**
Contributors can specify which version of the functional test suite to use:
```bash
# test-config/test-version.txt
v1.3.0
```

**2. Define Expected Passing Tests**
Contributors specify which tests should pass for the current DocumentDB version:
```yaml
# test-config/test-expectations.yaml
version: "documentdb-2.0"
expected_passing:
  - test_find_basic_queries
  - test_find_with_projection
  - test_aggregate_match_stage
  - test_decimal_precision  # Now supported in v2.0
expected_failing:
  - test_full_text_search   # Not yet implemented
  - test_advanced_geospatial # Planned for v2.1
```

**3. Add Test Behavior Overrides**
Contributors can provide DocumentDB-specific test behavior when needed:
```python
# test-config/overrides/test_decimal_precision_override.py
@pytest.mark.find
@pytest.mark.override("test_decimal_precision")
def test_decimal_precision_documentdb(collection):
    """DocumentDB version with specific precision handling"""
    result = collection.find({"price": Decimal128("123.456789012345678901234567890123456789")})
    
    # DocumentDB-specific assertion
    actual = str(result[0]["price"])
    assert len(actual) <= 34, f"DocumentDB precision limit: {actual}"
```

**Override Implementation Details:**

Test overrides are implemented using a custom pytest plugin that modifies the test collection phase. When `--overrides-dir` is specified, the plugin:

1. **Discovers override files** in the specified directory during pytest collection
2. **Identifies override functions** marked with `@pytest.mark.override("original_test_name")`
3. **Replaces original test items** in the collection with override implementations
4. **Maintains test metadata** (markers, fixtures, etc.) from the override function

```python
# Plugin implementation (simplified)
def pytest_collection_modifyitems(config, items):
    overrides_dir = config.getoption("--overrides-dir")
    if not overrides_dir:
        return
    
    # Load override functions
    override_map = discover_overrides(overrides_dir)
    
    # Replace original tests with overrides
    for i, item in enumerate(items):
        if item.name in override_map:
            items[i] = create_test_item(override_map[item.name])
```

**Benefits:**
- **Clean separation**: Override logic is isolated in the plugin
- **Transparent execution**: Tests run normally, overrides are invisible to pytest
- **Extensible**: Plugin can support advanced features like conditional overrides
- **Maintainable**: Standard pytest plugin architecture with clear boundaries

**4. GitHub Actions Integration**
The DocumentDB repository CI automatically uses contributor configuration:
```yaml
# .github/workflows/functional-tests.yml
name: Functional Tests
on: [pull_request, push]
jobs:
  functional-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Read test configuration
        run: |
          TEST_VERSION=$(cat test-config/test-version.txt)
          echo "TEST_VERSION=$TEST_VERSION" >> $GITHUB_ENV
      - name: Run functional tests
        run: |
          docker run documentdb/functional-tests:$TEST_VERSION \
            --connection-string ${{ secrets.DOCUMENTDB_URL }} \
            --test-config ./test-config/test-expectations.yaml \
            --overrides-dir ./test-config/overrides/ \
            --results-output ./test-results/current.json
      - name: Validate test results
        run: |
          validate-test-results \
            --results ./test-results/current.json \
            --config ./test-config/test-expectations.yaml \
            --fail-on-regressions
```

**Contributor PR Workflow:**
1. **Update test version** if needed in `test-config/test-version.txt`
2. **Modify expected results** in `test-config/test-expectations.yaml` for new features
3. **Add overrides** in `test-config/overrides/` for DocumentDB-specific behavior
4. **Submit PR** - GitHub Actions automatically runs tests with new configuration
5. **Review results** - CI shows which tests pass/fail compared to expectations
