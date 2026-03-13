---
rfc: 0017
title: "BSON Indexing Strategy"
status: Draft
owner: "@nitinahuja89"
issue: "https://github.com/documentdb/documentdb/issues/XXX"
discussion: "https://github.com/documentdb/documentdb/discussions/XXX"
version-target: 1.0
implementations:
  - "TBD"
---

# RFC-0017: BSON Indexing Strategy

## Problem

DocumentDB users need flexible indexing options to optimize for their specific workloads. Currently, DocumentDB supports only Extended RUM indexes. While Extended RUM excels at full-text search and native multikey indexing, its performance characteristics create challenges:

1. **Write-heavy workload bottlenecks** - Extended RUM generates significant WAL (Write-Ahead Log), which creates multiple issues:
   - **Replication lag**: More WAL data must be shipped and applied to replicas, causing read replicas to fall behind the primary
   - **Disk space exhaustion**: WAL files can accumulate faster than they can be archived or cleaned up, potentially filling disk space and causing database outages
   - **I/O contention**: High WAL write volume increases I/O pressure, impacting overall database performance
2. **Limited index type options for workload optimization** - With only Extended RUM available, users cannot choose lighter-weight indexes for scenarios where Extended RUM's advanced capabilities (full-text search, native multikey) are not needed but its operational overhead (WAL generation, write performance, index size, build time) creates challenges

### Who is impacted?

- **Application developers** building on DocumentDB applications
- **Database administrators** managing production deployments
- **Operations teams** responsible for database infrastructure

### Consequences of not solving

Without solving this problem:
- Write-heavy workloads will continue to experience replication lag, disk space exhaustion risks, and I/O bottlenecks
- Users cannot optimize for workloads that don't need Extended RUM's advanced features but suffer from its operational overhead
- Operational complexity increases due to manual WAL space management and monitoring
- Simple scalar field indexes incur Extended RUM's overhead even when its advanced capabilities are not needed

### Current workarounds

Currently, users must:
- Accept Extended RUM's operational impacts including replication lag, disk space management, and I/O pressure
- Avoid indexing certain fields to reduce write overhead
- Use Extended RUM even when simpler index types would suffice and provide better operational characteristics

### Success criteria

This RFC succeeds when:
1. Users can choose between multiple index types via the createIndex API
2. Clear guidelines and performance characteristics are documented for each index type
3. Write-heavy workloads achieve lower WAL generation

### Non-goals

This RFC does NOT:
- Change the underlying Extended RUM implementation
- Replace or deprecate Extended RUM indexes
- Require users to rebuild existing indexes
- Automatically migrate indexes (users choose when to change index types)
- Create a single unified index type that handles all workloads

---

## Approach

### What is Extended RUM?

Extended RUM builds on PostgreSQL's RUM index with critical enhancements for document database indexing:

* **Ordered index scans** - Supports B-Tree-like traversal over inverted indexes
* **Hybrid indexing** - Combines GIN-style filtering + RUM addInfo + ordered/B-Tree-style queries
* **Rich operator extensibility** - Custom ordering, fast-scan control, configurable behavior
* **Multi-predicate optimization** - Improved performance via optimized fast scans and posting-tree skipping
* **Covering queries** - Supports index-only query capabilities
* **Parallel operations** - Enables parallel index build and parallel scans
* **Efficient maintenance** - Improved vacuum efficiency for large inverted indexes
* **Diagnostics** - Built-in diagnostics and repair utilities for index health and recovery

This is the index type supported by the OSS DocumentDB project (pg_documentdb_extended_rum).

### Index Type Comparison

| Capability | Extended RUM | B-tree |
|-----------|--------------|--------|
| **Multikey (array) indexes** | Native support | Custom logic support - performance TBD |
| **Compound multikey indexes** | Native support | Custom logic support - performance TBD |
| **Full-text search** | ✅ Unique capability | ❌ Not supported |
| **Full-text + sorting combined** | ✅ In single index | ❌ Not supported |
| **Range queries** (>, <, BETWEEN) | ✅ Supported | ✅ Expected better performance - benchmarking TBD |
| **Sorting** (ORDER BY) | ✅ Via order-by pushdown | ✅ Expected better performance - benchmarking TBD |
| **Write performance** | ⚠️ Slower | ✅ Faster |
| **WAL generation** | ⚠️ Higher - can cause replication lag | ✅ Lower - less replication impact |
| **Index size** | ⚠️ Larger | ✅ Smaller |
| **Index build time** | ⚠️ Slower - inverted index construction | ✅ Faster - tree construction |
| **Parallel index build** | ✅ Supported | ✅ Supported |

### When to Use Extended RUM Index

Create an Extended RUM index when you need:

* **Array/multikey indexing** - Native support for indexing all array elements (B-tree will also support this with custom logic, but performance comparison TBD)
* **Full-text search** - Search text content within documents, especially with ordering (B-tree cannot do this)
* **Compound indexes with arrays** - Index both scalar and array fields together (B-tree will support with custom logic, performance TBD)
* **Text search + ordering** - Need both capabilities in a single efficient index

**Important considerations:**
* Slower writes, larger index size, and longer build times compared to B-tree
* High WAL generation - can cause replication lag or run out of WAL space in high-write scenarios
* Index builds can be time-consuming on large collections (both index types support parallel builds and CONCURRENTLY option to avoid blocking writes)

### When to Use B-tree Index

Create a B-tree index when you need:

* **Range queries** - Efficient filtering with >, <, >=, <=, BETWEEN on dates or numbers (expected better performance - benchmarking TBD)
* **Sorting** - ORDER BY operations on non-text fields (expected better performance - benchmarking TBD)
* **Exact value lookups** - Lookups with exact value (performance comparison TBD)
* **Fast writes** - Write-heavy workloads where index maintenance speed matters
* **Low replication lag** - Lower WAL generation compared to Extended RUM
* **Array fields** - Will be supported with custom logic (performance comparison with Extended RUM TBD)

**Important considerations:**
* Faster index builds compared to Extended RUM
* Lower storage overhead
* Both index types support CONCURRENTLY builds to avoid blocking concurrent writes during index creation

**Not suitable for:** Full-text search

### Recommended Strategy

This RFC proposes supporting both Extended RUM and B-tree index types, allowing customers to choose based on their workload needs.

For most customers:

1. **Evaluate workload requirements** - Analyze query patterns, write volume, and operational constraints
2. **Choose appropriate index type** - Use Extended RUM for full-text search and native multikey support; use B-tree for write-heavy workloads, range queries, and sorting
3. **Monitor in production** - Track WAL generation, replication lag, and query performance
4. **Optimize as needed** - Adjust index types based on actual usage patterns (see deployment strategies below)

### Deployment Strategies

| Strategy | Best For | Trade-offs |
|----------|----------|------------|
| **Extended RUM only** | Full-text search (unique capability); native multikey if performance critical; workloads where Extended RUM's strengths outweigh WAL costs | Slower writes; high WAL generation (replication lag risk) |
| **B-tree only** | Write-heavy scenarios; low replication lag critical; workloads where B-tree performance characteristics align with requirements (subject to benchmarking); multikey via custom logic if performance acceptable | No full-text search; custom multikey support; range/sort performance benefits need benchmarking |
| **Hybrid (both indexes)** | Full-text search on some fields + range/sort optimization on others; need best performance for each operation type | Dependent on which fields have which index type |

### Benefits

This approach delivers:
1. **Workload optimization** - Users can match index type to query patterns
2. **Performance flexibility** - Trade write speed for query capabilities or vice versa
3. **Feature completeness** - Support for array indexing and text search
4. **Operational control** - Manage WAL generation and replication lag

### Design Rationale

**Why support both?** Different workloads have fundamentally different needs. Full-text search requires Extended RUM's inverted index structure, while write-heavy workloads benefit from B-tree's lower operational overhead (WAL, writes, storage).

**Why not merge into one index type?** The fundamental trade-offs are inherent to the index structures:
- Extended RUM: Essential for full-text search, but generate more WAL and have slower writes
- B-tree: Lower WAL and faster writes, but cannot efficiently support full-text search

Extended RUM already adds tree-like traversal capabilities to an inverted index, but this doesn't eliminate the operational overhead. The trade-offs remain: choose inverted index characteristics (text search capability) or tree characteristics (low WAL, fast writes).

**Why not default to one type?** Different workloads have different priorities. Supporting both allows users to optimize for their specific requirements.

### Summary

Based on the analysis above, the recommendation is to **support both Extended RUM and B-tree index types**, giving customers the flexibility to optimize for their specific workloads. Each index type has distinct strengths that complement each other, and no single index can efficiently handle all workload patterns.

**Note:** Both index types are created on specific field paths extracted from BSON documents, not on the entire document.

---

## Detailed Design

*Implementation details will be defined during the implementation phase. Key aspects to address include:*

- API for specifying index type during index creation
- Query planner integration to choose appropriate index based on query patterns
- Performance benchmarking to validate assumptions
- Migration guidance for users wanting to switch index types
- Backwards compatibility with existing Extended RUM indexes

