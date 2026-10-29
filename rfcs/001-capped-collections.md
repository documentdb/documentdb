# Design Document: Capped Collections for DocumentDB

## 1. Introduction

This document outlines the design options for implementing MongoDB-compatible capped collections in DocumentDB. Capped collections are fixed-size collections that maintain insertion order and automatically remove old documents when the collection reaches its size limit.

## 2. Capped Collection Behavior

Key behaviors to support:
- Fixed maximum size with automatic circular reuse of space
- Optional maximum document count limit
- Insertion order preservation (natural order)
- No deletion of documents (only automatic removal when limits are exceeded)
- No size-increasing updates allowed
- Support for tailable cursors
- Support for `convertToCapped` operation

## 3. Out of Scope Features

The following features related to capped collections are out of scope for the current implementation and will be addressed separately:

- **Tailable Cursors**: The ability to create cursors that remain open after returning the last result, allowing for continuous monitoring of a capped collection. This feature will be discussed and implemented separately.

## 4. Topic 1: Enforcing maximum size/ document limits

This topic covers how we will enforce the maximum size and optionally maximum document count limit for capped collections.

### 4.1 Row-Based Trigger

**Description:**
Trigger fires for each row inserted, checking collection size/document limits and removing oldest documents as needed.

**Overview:**
This approach implements capped collection functionality by attaching row-level triggers for tables which store capped collection data. Every time a document is inserted, a trigger function executes to check if the collection has exceeded its configured size or document count limits. If limits are exceeded, the trigger removes the oldest documents based on insertion order.

The approach centers around PG's row-level trigger system. After each insert operation the trigger does the following:
1. Fetch the current collection size and document count from the metadata
2. Compare against the configured limits
3. Identify and remove the oldest documents if necessary
4. Update the collection size and document count in the metadata

We keep the collection size and document count up-to-date in the metadata after each insertion so that it doesn't need to be recomputed each time.    
This approach allows us to support all the required behaviours for capped collections.

**Pros:**
- The capped collection is always under the desired limits since the limit is enforced at each document insert
- Relatively simple implementation using standard PG features

**Cons:**
- Trigger firing for every row incurs overhead and hence significant performance impact (specially for bulk inserts)
- Creates dead tuples that would require vacuuming

### 4.2 Statement-Based Trigger

**Description:**
Triggers fire once after each statement completes, checking collection size/document limits and removing oldest documents in batch if needed.

**Overview:**
This approach implements capped collection functionality using statement-level triggers that execute once per SQL statement rather than once per inserted row. When a statement completes (potentially inserting multiple documents), a trigger function executes to enforce size constraints.

The implementation uses PG's AFTER STATEMENT trigger which:
1. Fetch the current collection size and document count from the metadata
2. Compare against the configured limits
3. Perform a single cleanup operation that removes enough oldest documents to bring the collection within its limits
4. Update the collection size and document count in the metadata

This method is more efficient for bulk operations as it performs a single evaluation and cleanup per statement rather than per row. It maintains MongoDB compatibility while offering better performance for common write patterns involving multiple documents.

**Pros:**
- The capped collection is always under the desired limits since the limit is enforced for each statement
- Better performance for bulk operations due to efficient batch cleanup of oldest documents

**Cons:**
- Performance impact for single inserts due to triggers
- Creates dead tuples that would require vacuuming

### 4.3 Background Worker

**Description:**
A background process periodically checks capped collections and removes oldest documents to be under the size/document limits.

**Overview:**
This approach implements capped collection functionality by using a dedicated background worker that runs on a periodic schedule (e.g., every few seconds) to manage collection sizes. Rather than enforcing limits during insert operations, this approach separates the concerns of writing data and maintaining size limits.

The implementation relies on PG's background worker infrastructure, where a scheduled process:
1. Scans through all capped collections in the system
2. For each collection, checks if size or document count limits are exceeded
3. Performs cleanup operations to remove oldest documents as needed

This approach minimizes the performance impact on insert operations since size enforcement happens asynchronously, but may allow collections to temporarily exceed their configured limits between background worker runs.

**Pros:**
- No impact on insert performance
- Efficient batch cleanup operations

**Cons:**
- Potential for temporary size exceedance during high insert throughput and thereby less compatible with MongoDB
- Creates dead tuples that would require vacuuming
- Resource usage by a separate background worker

### 4.4 Table Partitioning

**Description:**
Create time-based or sequence-based partitioned tables, dropping oldest partitions when size limits are exceeded.

**Overview:**
This approach implements capped collection functionality by leveraging PG's native table partitioning features. Collections are created as partitioned tables, with each partition containing a range of documents based on insertion order or timestamp. Instead of deleting individual documents, entire partitions are dropped.

The approach creates:
1. A parent partitioned table using PG's PARTITION BY RANGE feature
2. Child partition tables, each holding a fixed range of the insertion sequence (e.g., 1-1000000, 1000001-2000000, etc.)
3. A management mechanism that creates new partitions as needed and drops the oldest partitions when size limits are exceeded

**Partition Management Mechanism:**

Several options exist for implementing the partition management mechanism:

1. **Row-Level Trigger Approach**:
   - A trigger fires on each document insert
   - Checks if the current insertion value is approaching the upper boundary of the latest partition
   - Creates a new partition if needed
   - Periodically checks total collection size and drops oldest partitions if limits are exceeded

2. **Background Worker Approach**:
   - A background process runs periodically
   - Monitors all capped collections using partitioning
   - Creates new partitions when existing ones are nearing capacity
   - Drops oldest partitions when collection exceeds size/document limits

3. **Hybrid Approach**:
   - New partitions are created on-demand during the insert when an insertion would exceed current partition boundaries
   - A separate scheduled process (pg_cron or background worker) runs independently to enforce size limits by dropping old partitions
   - This hybrid solution balances immediate insertion performance with efficient batch cleanup by separating the two concerns

If we go with table partitioning, I would recommend the hybrid approach since it will guarantee that the critical task of creating new partitions when required happens during insertion (so that insertions always succeed) and we can hand-off the less critical task of dropping old partitions to a separate scheduled process. 

Key considerations for partition management include:
- **Partition Size**: Smaller partitions allow more precise size control but create management overhead
- **Boundary Selection**: Parition boundaries need to be decided based on partition size and optionally document count
- **Statistics Tracking**: Maintaining metadata about partition sizes helps optimize cleanup operations

This approach takes advantage of PG's efficient partition management operations, as dropping an entire partition is much faster than deleting individual rows. However, it operates at a coarser granularity, not allowing us to exactly maintain the size/document limits required by capped collections.

**Pros:**
- Minimal impact on insert performance
- Very efficient deletion through partition dropping
- It doesn't create dead tuples that require vacuuming

**Cons:**
- Capped collection limits not enforced immediately and thereby less compatible with MongoDB
- Partition management mechanism adds complexity

### 4.5 Custom Transaction Hook

**Description:**
Use PG's transaction hooks to check and enforce limits at transaction boundaries using collection statistics from shared memory.

**Overview:**
This approach implements capped collection functionality by integrating directly with PG's transaction management system. By registering a hook that executes during transaction commit processing, this approach can track document insertions and enforce size limitations as an integral part of the transaction lifecycle.

The implementation leverages PG's `RegisterXactCallback()` API with multiple hooks:
- `XACT_EVENT_PRE_COMMIT`: Executes just before a transaction commits but after all user operations are completed. This is the ideal point to perform the capped collection size enforcement because all document insertions for the transaction are complete, but the transaction hasn't been committed yet.
- `XACT_EVENT_COMMIT`: Executes after a successful commit to update statistics in both shared memory and persistent catalog.

For deleting older documents within the same transaction, we have two options:
- **Server Programming Interface (SPI)**: Execute SQL DELETE queries via SPI within the transaction hook, leveraging PG's query optimizer for deletion based on the insertion_order index
- **Direct Relation Access**: Directly access the relation to delete tuples, potentially offering lower overhead but with more complex implementation

The direct relation access to remove older documents would be the preferred choice to maintain good insert performance. 

Updating collection statistics:
1. **During normal operation**: Track document insertions and size changes in transaction-local memory, then update shared memory statistics after successful cleanup and commit
2. **On server startup**: Reload statistics from the catalog into shared memory, ensuring correct state is maintained across restarts

The approach creates:
1. Custom transaction commit hooks that execute before and after a transaction is committed
2. Shared memory structures to track the size and document counts of capped collections for efficient access
3. Pre-commit function that calculates the impact of a transaction on collection sizes and performs cleanup of oldest documents when necessary before allowing the transaction to complete
4. Post-commit function that updates both the shared memory statistics and the persistent catalog statistics to ensure consistency across server restarts

This approach integrates deeply with the engine offering better performance. It maintains consistent collection sizes through transaction boundaries by handling size enforcement as part of the commit process.

**Pros:**
- The capped collection is always under the desired limits since the limit is enforced as part of the transaction commit process
- Potentially lower overhead than triggers for insert performance
- Better performance due to efficient batch cleanup of oldest documents at the time of transaction commit

**Cons:**
- Slightly complex to implement and maintain than trigger-based approaches
- Creates dead tuples that would require vacuuming

### 4.6 Custom Table Access Method

**Description:**
Implement a specialized storage engine specifically for capped collections by creating a custom Table Access Method (AM) that directly manages physical storage with circular buffer semantics.

**Overview:**
This approach implements capped collection functionality by creating a custom Table Access Method that operates at a lower level than standard PG tables. By implementing our own storage manager for capped collections, we gain precise control over the physical placement of documents and can perform in-place document replacements without MVCC overhead.

The approach would include:

1. **Custom Physical Storage Format**:
   - A specialized file format optimized for circular buffer operations
   - Header with metadata (max size, write position, etc.)
   - Fixed-size physical segments for efficient storage management
   - Direct byte positioning and document boundary tracking

2. **Implementation of TableAmRoutine**:
   - Custom versions of scan, insert, update, and delete operations optimized for circular buffer semantics
   - Specialized visibility rules that simplify version management
   - Direct physical storage manipulation without MVCC overhead

3. **Buffer Management Integration**:
   - Integration with PG's buffer management system
   - Custom buffer operations that understand the circular nature of the storage
   - Specialized buffer replacement strategy optimized for capped collections

4. **Transaction Management**:
   - WAL logging for crash recovery
   - Atomic operations for document replacement at the physical level

5. **Indexing and Performance**:
   - Specialized indexing integration for natural order queries
   - Memory-mapping for high-performance access

**Pros:**
- Maximum performance by bypassing MVCC overhead
- No dead tuples generated (true in-place replacements)
- No vacuum required for document replacement
- Optimal space utilization without fragmentation
- Perfect control over document replacement policy

**Cons:**
- Very high implementation complexity to implement new table access method
- Requires careful integration with PG's buffer management, crash recovery, and indexing
- Require extensive testing to ensure correctness under all conditions
- Higher maintenance effort as PG evolves

### Recommendation

| Criteria | Row-Based Trigger | Statement-Based Trigger | Background Worker | Partitioning | Transaction Hook | Custom Table Access Method |
|----------|-------------------|--------------------------|-------------------|--------------|------------------|----------------|
| MongoDB Compatibility | High | High | Medium | Low | High | High |
| Performance | Low | Medium | High | Very High | High | Very High |
| Vacuuming for deleted documents | Yes | Yes | Yes | No | Yes | No |
| Implementation Complexity | Medium | Medium | Medium | High | High | Very High |
| Maintenance | Simple | Simple | Medium | Complex | Complex | Very Complex |

The ideal approach would be to implement a specialized storage engine via a custom table access method. However, that will have a much higher implementation and maintenance complexity than any other approach. We could evaluate this approach further to assess the cost-benefit of this approach. The next best option is to use a custom transaction hook approach since it provides good performance in addition to MongoDB compatibility at a reasonable implementation and maintenance cost.

## 5. Topic 2: Storage Schema

This topic covers how we will store and organize data for capped collections, including metadata storage and insertion order tracking.

### 5.1 Metadata Storage

The metadata storage approach determines how we track capped collection configuration and statistics.

#### 5.1.1 Extended Collections Table

**Description:**
This approach extends the existing collections table with additional columns specifically for capped collection properties and statistics.

**Overview:**
The collections table would be extended to include columns that indicate whether a collection is capped, its maximum size limit, maximum document count, current size, and current document count. This provides a centralized location for all collection metadata, keeping capped collection configuration alongside standard collection information.

**Pros:**
- Simple, centralized location for all collection metadata
- Easy to query for management and reporting tasks
- Follows the principle of keeping related information together

**Cons:**
- May become a concurrency bottleneck when frequently updating size statistics
- Less flexibility for adding capped collection-specific metadata in the future
- Mixes rarely-changed configuration with frequently-updated statistics

#### 5.1.2 Separate Capped Collections Metadata Table

**Description:**
This approach creates a dedicated table specifically for capped collection metadata and statistics.

**Overview:**
A new table would be created that references the main collections table and contains all capped collection-specific information. This table would include configuration parameters like maximum size and document limits, as well as operational statistics like current size and document count. This approach clearly separates capped collection concerns from regular collection metadata.

**Pros:**
- Separates concerns, keeping regular collections metadata unaffected
- Can include more specialized fields for capped collections
- Better for horizontal scaling and concurrency

**Cons:**
- Requires joins for some operations that need both regular and capped collection metadata
- More complex schema management with an additional table

#### Recommendation
I would recommend having a separate capped collection metadata table to avoid concurrency bottlenecks on the primary collection metadata table when capped collection statistics are updated. 

### 5.2 Insertion Order Tracking

Tracking insertion order is essential for capped collections to ensure natural order queries and document cleanup.

#### 5.2.1 SERIAL/BIGSERIAL Column

**Description:**
This approach adds an auto-incrementing column to document tables for tracking insertion order.

**Overview:**
A SERIAL or BIGSERIAL column would be added to the documents table for capped collections. This column would automatically generate sequential values for each inserted document, providing a reliable way to determine the insertion order. The database would manage this sequence internally, ensuring uniqueness and proper ordering.

**Pros:**
- Simple, built-in PG feature with minimal implementation effort
- Easy to query and index
- Automatically maintained by the database system
- Handles concurrent inserts properly

**Cons:**
- The sequence generator may become a concurrency bottleneck for high-volume inserts
- Less control over value assignment and sequence management

#### 5.2.2 DocumentDB Managed Monotonic Values

**Description:**
In this approach the DocumentDB extension explicitly assigns monotonically increasing values for tracking insertion order.

**Overview:**
The DocumentDB engine would maintain a counter for each capped collection and assign insertion order values to documents as they're inserted. This counter would be managed in shared memory for performance, with persistence to disk for durability across restarts. Transaction-safety mechanisms would ensure correct ordering even with concurrent operations and aborted transactions.

**Pros:**
- More control over sequence management allows for optimizations like pre-allocating blocks of sequence values to a session to reduce lock contention

**Cons:**
- More complex implementation requiring careful synchronization, persistence for recovery scenarios and failure handling

#### Recommendation
I recommend starting with the simple approach of using a built-in PG feature to generate the sequence for tracking insertion order. If we find performance bottlenecks with this approach in high throughput write workloads then we can explore the option to have our self managed monotonic values. 


## 6. Topic 3: Delete/Update Constraint Enforcement

This topic covers how we will enforce the constraints of preventing explicit DELETE operations and preventing size-increasing UPDATEs.

### 6.1 Enforcement of Delete Constraint

The following approaches can be used to enforce this constraint.

#### 6.1.1 Row-Level Triggers

**Description:**
This approach uses row-level triggers that check the session variables to determine if deletion operations should be allowed or rejected.

**Overview:**
A BEFORE DELETE trigger is attached to tables storing capped collection data. When a deletion is attempted, the trigger checks if the operation is coming from an internal enforcement mechanism (such as automatic cleanup when size limits are exceeded) or from an external user request. Internal operations are allowed to proceed, while external deletion attempts are rejected with an error message.

**Pros:**
- Simple implementation using standard PG features
- Provides separation between internal maintenance operations and user operations

**Cons:**
- Small performance overhead for every deletion operation
- Relies on session variables to allow internal delete operations that must be properly managed

#### 6.1.2 Row Security Policies (RLS)

**Description:**
This approach uses PG's Row Level Security to control which roles can perform DELETE operations on capped collections.

**Overview:**
Row Level Security policies are defined on tables storing capped collection data to prevent DELETE operations except when performed by specific system roles or when special session variables are set. This provides a declarative way to restrict deletion capabilities at the database level.

**Pros:**
- Uses standard PG permission model
- Potentially more efficient than triggers for high-throughput scenarios

**Cons:**
- Incurs overhead for each row because policy expressions would be evaluated for each row
- Less specific error messages compared to triggers

#### 6.1.3 Table-Level Privilege Restriction

**Description:**
This approach uses PG's permission system to restrict DELETE privileges on the capped collection table at the role level.

**Overview:**
DELETE privileges on capped collection tables are revoked from regular user roles and granted only to special system roles used for internal maintenance operations. This creates a clear separation of capabilities between regular users and system maintenance processes.

**Pros:**
- Uses standard PG permission model
- Permission check happens only once at the start of the statement

**Cons:**
- Less flexibility for fine-grained control
- Less specific error messages compared to triggers

#### 6.1.4 Core Delete Function Integration

**Description:**
This approach integrates delete constraint enforcement directly into DocumentDB's core delete processing functions, checking for capped collections at the entry points for both single and bulk delete operations.

**Overview:**
This approach implements the delete prevention by adding validation directly in the code paths used for all delete operations. Since DocumentDB has separate paths for single-document and bulk deletes, a common helper function would be created and called from both entry points to ensure consistent enforcement of the constraint.

The implementation adds checks to:
1. The single-document delete path (`DeleteOneInternalCore`)
2. The bulk delete path (`DeleteAllMatchingDocuments`) 

The check validates whether the target collection is capped and whether the operation is coming from an internal process. If the collection is capped and the operation is external, it's rejected with an appropriate error message. This ensures that all delete paths are covered while keeping the check logic centralized.

**Pros:**
- Enforces constraint at the lowest level ensuring all delete paths are covered
- Minimal performance overhead
- Provides specific, MongoDB-compatible error messages

**Cons:**
- Needs additional context information about the collection (check if capped collection) to enforce the constraint
- Must be carefully maintained ensuring that all delete path have this check

#### Recommendation

I recommend that we integrate the contraint check in the core delete functions since it allows providing specific MongoDB compatible error messages with minimal performance overhead. 

### 6.2 Enforcement of Update Size Constraint

Capped collections do not allow updates that increase document size. The following approaches can be used to enforce this constraint.

#### 6.2.1 Row-Level Triggers

**Description:**
This approach uses row-level triggers that compare the size of the original document with the updated document.

**Overview:**
A BEFORE UPDATE trigger is attached to tables storing capped collection data. When an update is attempted, the trigger compares the size of the old document with the size of the new document. If the size would increase, the update is rejected with an error message.

**Pros:**
- Precise size checking at the document level
- Clear error messages for better user experience
- Simple implementation using standard PG feature

**Cons:**
- Performance overhead for every update operation due to the row-level trigger

#### 6.2.2 Core Update Function Integration

**Description:**
This approach integrates size checking directly into DocumentDB's core document update processing function.

**Overview:**
The constraint is implemented in the `BsonUpdateDocumentCore` function, which is the central point where all document updates are processed. The implementation adds a check that compares the size of the source document with the updated document for capped collections.

**Pros:**
- Single implementation point for enforcing size constraint at the lowest level ensuring all update paths are covered
- Minimal performance impact

**Cons:**
- Needs additional context information about the collection (check if capped collection) to enforce the size constraint

#### Recommendation
The recommendation is to choose the approach to add the size check in the core update function since it provides a single implementation point with minimal performance overhead.
