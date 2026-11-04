---
rfc: 0015
title: "Logical Session Management"
status: Proposed
owner: "@tsharp"
issue: "https://github.com/documentdb/documentdb/issues/XXX"
discussion: "https://github.com/documentdb/documentdb/discussions/XXX"
version-target: 1.0
implementations:
  - "https://github.com/documentdb/documentdb/pull/XXX"
---

# RFC-0015: Logical Session Management

## Problem

The DocumentDB Gateway lacks direct logical session management. Session context is inferred indirectly from cursor and transaction state rather than tracked explicitly, preventing reliable session ownership and lifecycle enforcement. This causes session-scoped resources to remain open longer than intended, or indefinitely, with no deterministic cleanup path.

### Impact on Applications

Clients that use session-scoped cursors and transactions face three issues:
1. Resources tied to a session may not be cleaned up when the session ends, leading to unexpected behavior and potential resource exhaustion
2. No guarantee that `endSessions` or `killSessions` commands promptly release all associated resources
3. `refreshSessions` cannot be implemented directly.

### Impact on the Gateway

Without direct session tracking, the gateway has three operational problems:
1. Session ownership cannot be verified: a cursor or transaction opened by one user can be accessed by another
2. Cleanup of session-bound resources requires broad O(n) scans across all cursors and transactions rather than O(k) direct lookups per session
3. Resource cleanup relies on ad-hoc, indirect paths that are incomplete and prone to leaks

### Current State

Session IDs are stored as bare fields on `GatewayTransaction` and `CursorStoreEntry` with no dedicated structure to track session lifetime or provide direct mechanisms for lifecycle management:

[pg_documentdb_gw/documentdb_gateway_core/src/context/transaction.rs](https://github.com/documentdb/documentdb/blob/d4840e60f5049212a2de7d490eb7e5060a252d65/pg_documentdb_gw/documentdb_gateway_core/src/context/transaction.rs)
```rust
pub struct GatewayTransaction {
    pub session_id: Vec<u8>,
    pub transaction_number: i64,
    pub cursors: CursorStore,
    pg_transaction: Option<postgres::Transaction>,
}
```

[pg_documentdb_gw/documentdb_gateway_core/src/context/cursor.rs](https://github.com/documentdb/documentdb/blob/d4840e60f5049212a2de7d490eb7e5060a252d65/pg_documentdb_gw/documentdb_gateway_core/src/context/cursor.rs)

```rust
#[derive(Debug)]
pub struct CursorStoreEntry {
    pub conn: Option<Arc<Connection>>,
    pub cursor: Cursor,
    pub db: String,
    pub collection: String,
    pub timestamp: Instant,
    pub cursor_timeout: Duration,
    pub session_id: Option<Vec<u8>>,
}
```

Sessions are partially implicit. There is not a `LogicalSession` entity that owns or tracks the cursors and transactions associated with it. A session only "exists" on the server insofar as there are active cursors or transactions carrying that session ID. The gateway has no independent record of when the session was created, when it was last used, or what resources belong to it. This makes it impossible to enforce session expiry, validate ownership, or perform direct cleanup without scanning all cursors and transactions.

### Success Metrics

This RFC MUST achieve:
1. Sessions are explicitly associated with their cursors and transactions at creation time
2. Session ownership is validated on all session-scoped operations
3. `endSessions` and `killSessions` achieve O(k) cleanup per session rather than O(n) scans
   - k represents the total count of transactions and cursors owned by a given session. 
   - n represents the total count of all transactions and cursors across all sessions.
4. `refreshSessions` MUST reset the timeout duration of the session to allow for long running sessions.
5. Session termination (whether via `endSessions`, `killSessions`, or idle timeout expiry) cascades cleanup of all associated cursors and transactions deterministically.
6. Sessions expire after 30 minutes of idle time, consistent with `localLogicalSessionTimeoutMinutes`.
7. Implicit session creation is still supported
8. `startSession` command is supported
9. User ownership is enforced over Sessions, Cursors and Transactions.

### Non-Goals

This RFC explicitly does NOT:
- Implement support for `$listSessions` or `$listLocalSessions`

---

## Approach

The proposed solution is to introduce `LogicalSession` as a first-class entity in the gateway, backed by a new `InMemorySessionStore` that owns the mapping from a session ID to its associated transactions and cursors. This gives the gateway an authoritative, independently queryable record of every active session, including its creation time, last-used timestamp, and the set of resource IDs it owns.

### Core Ideas

**1. InMemorySessionStore as the authority for session state**

A new `InMemorySessionStore` will be introduced alongside the existing `TransactionStore` and `CursorStore`. At the point a session-scoped resource is created, it is registered in `InMemorySessionStore`, which records the session ID, creation timestamp, and the IDs of all child transactions and cursors. This eliminates the need to scan child stores to answer "what belongs to this session?".

**2. Top-down cascading cleanup**

Cleanup flows strictly in one direction: `InMemorySessionStore` → `TransactionStore` → `CursorStore`. When a session is terminated (via `endSessions`, `killSessions`, idle timeout, or expiry), the `ServiceContext` background task removes it and enqueues its owned transactions and cursors for cleanup. Stores do not reference each other. This parent-owns-children model makes cleanup deterministic and prevents circular dependencies.

**3. Replace the DashMap-based cleanup task with a non-locking `CacheMap`**

The existing per-store cleanup task is built on DashMap, a locking structure that creates thread contention under high concurrency. A new `CacheMap` structure, backed by `papaya::HashMap`, will be implemented and used as the foundation for all three stores (session, transaction, and cursor). `CacheMap` provides consistent TTL enforcement without locking overhead. Cleanup and compaction cycles will run in a new background task owned by `ServiceContext`, replacing the per-store cleanup approach.

**4. Distinct ID types**
- [x] [PR #552: [OSS][GW] Uniform Identifiers for Session, Transaction and Cursor](https://github.com/documentdb/documentdb/pull/552/commits/f2eb1abfcd76b42cbc71ac3126ef5ab3bad34ebb)

Separate newtype wrappers (`SessionId`, `TransactionId`, `CursorId`) will be introduced to prevent accidental confusion of raw identifiers (`Vec<u8>`, `u64`, `i64`) across the codebase, improving type clarity and safety at the call site.

### Key Tradeoffs

| Tradeoff | Benefit | Cost |
|---|---|---|
| Cursor timeouts are independent of session TTL | Prevents resource exhaustion from indefinitely refreshed cursors | Cursors are not refreshed when `refreshSessions` is called |
| Top-down-only cleanup graph | Deterministic cascading, no cycles | Parent metadata may temporarily hold stale child IDs (tolerated, lazily compacted) |
| `CacheMap` backed by `papaya::HashMap` | Uniform TTL and eviction behavior, reduced lock contention | Migration cost to replace existing DashMap-based stores |

### Alignment with Existing Architecture

This approach extends the existing `ServiceContext` pattern: `InMemorySessionStore` is constructed alongside `TransactionStore` and `CursorStore`, with the `ServiceContext` background task holding references to all three and driving cleanup. No changes to the wire protocol or backend (PostgreSQL) are required.

---

## Detailed Design

*This section MAY BE REQUIRED before moving from Proposed to Accepted status. This section MUST be completed and approved to move to Implementing status.*

**Purpose:** Provide comprehensive technical details needed for implementation.

**Complete this section when:** Your solution approach has been validated and you're ready to commit to specific implementation details.

**Guidance:** This is where you get specific. Include enough detail that someone could implement this RFC without having to make major design decisions.

### Technical Details

#### Data Structures

**`LogicalSession`**

A new `LogicalSession` struct will be introduced as a first-class entity. It tracks the session ID, last-used timestamp, and the IDs of all owned cursors and transactions. This is an illustrative sketch; the final field types and layout will be determined during implementation:

```rust
pub struct LogicalSession {
    session_id: SessionId,
    timestamp: AtomicU64,
    cursors: HashSet<CursorId>,
    transaction_id: Option<TransactionId>,
}
```

`cursors` uses `HashSet<CursorId>` rather than `Vec<CursorId>` to provide O(1) removal when a cursor is killed or expires, avoiding a linear scan over the owned set. `CursorId` wraps a `u64`, so its `Hash` and `Eq` implementations are cheap.

**Cleanup hints, not liveness records.** `LogicalSession.cursors` and `LogicalSession.transaction_id` are cleanup hints, not authoritative liveness records. The `CursorStore` and `TransactionStore` are the single source of truth for whether a given resource is still live. The session's sets may transiently contain stale IDs (for cursors that were evicted globally before their owning session was cleaned up); idempotent removal in the downstream stores means stale IDs produce safe no-ops during cleanup. This avoids the need for a back-reference from each cursor or transaction to its owning session, preserving the top-down-only cleanup graph.

An inverted index in `CursorStore` (`HashMap<SessionId, HashSet<CursorId>>`) was considered as an alternative to eliminate stale IDs entirely, but was rejected: it requires coordinated two-phase writes on every cursor eviction and adds a second index to a high-throughput store. The marginal benefit — avoiding no-op removals during session cleanup — does not justify that complexity.

**Distinct ID newtypes**

To prevent accidental misuse of raw identifiers across stores, dedicated newtype wrappers will be introduced:

```rust
pub struct SessionId(Vec<u8>);
pub struct CursorId(u64);
pub struct TransactionId(i64);
```

**`CacheMap`**

A new `CacheMap<K, V>` structure will be implemented, backed by `papaya::HashMap`, to replace the existing DashMap-based stores. `CacheMap` provides:
- Per-entry TTL with configurable expiration type (fixed or sliding)
- On access, if an entry has expired, `None` is returned; the entry is **not** removed at access time
- Physical removal of expired entries is the background task's responsibility
- Non-locking concurrent access suitable for high-throughput request paths

At 1M entries, memory consumption is approximately 117 MB (not including the owned session, cursor, and transaction objects).

**`InMemorySessionStore`**

`InMemorySessionStore` wraps a `CacheMap<SessionId, LogicalSession>`. The stores do not reference each other; cascading cleanup is driven entirely by the `ServiceContext` background task, which holds references to all three stores directly.

#### Resource Binding and Ownership

Resources are bound at creation time and cannot change binding:

| Resource | Binding options |
|---|---|
| Session | Always top-level |
| Transaction | Global, or bound to a session |
| Cursor | Global, transaction-bound, or session-bound |

A session may own at most one active transaction. Starting a new transaction while one is already active aborts the previous transaction if it has not been committed.

#### Timeout Behavior

| Kind | Expiration Type | Refresh on Access | Default Timeout |
|---|---|---|---|
| Session | Fixed | Yes (`refreshSessions` or read/write activity) | 30 minutes |
| Transaction | Fixed | No | 60 seconds (configurable) |
| Cursor (persisted) | Sliding | Yes (on `getMore`) | 60 seconds |
| Cursor (streaming) | Sliding | Yes (on `getMore`) | 10 minutes |
| Cursor (transaction-bound) | Fixed | No | Shares owning transaction TTL |

Cursor timeouts are independent of session TTL by default. `refreshSessions` resets the session timeout only; it does not extend cursor or transaction lifetimes unless `useSessionBoundCursorLifetime` is enabled. When `useSessionBoundCursorLifetime` is enabled, cursor lifetime snaps to the session lifetime regardless of cursor type, and `refreshSessions` refreshes all associated cursor lifetimes simultaneously. Transaction-bound cursors always share the owning transaction's lifetime irrespective of this setting.

#### Session Lifecycle

A session's lifetime is tracked via a timestamp updated on each activity. There are no explicit state enum variants; liveness is determined entirely by TTL and store membership. A session's TTL is extended when:
- A cursor or transaction is created for it
- `refreshSessions` is called for it

Every resource moves through the following internal states:

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Created : session inserted into store
    Created --> Active : available for lookup
    Active --> EvictionRequested : TTL expiry / endSessions / killSessions / killAllSessions
    EvictionRequested --> RemovedFromIndex : background task processes item
    RemovedFromIndex --> FullyDropped : all live references released
    FullyDropped --> [*]
```

**How `EvictionRequested` is represented.** There is no flag, enum variant, or separate data structure on the entry itself. `EvictionRequested` *is* the TTL-expired state: `CacheMap.get()` checks the entry's expiry timestamp on every access and returns `None` if the deadline has passed, without removing the entry. The expiry timestamp is a `u64` with two sentinel values: `u64::MIN` means the entry is immediately expired (evicted); `u64::MAX` means the entry never expires (used for resources with no configured TTL). For natural TTL expiry, the stored deadline is a computed absolute timestamp that becomes less than the current time once elapsed. For explicit eviction (`endSessions`, `killSessions`, `killAllSessions`), the eviction path atomically writes `u64::MIN` to the entry's expiry timestamp, then pushes the session ID onto the cleanup queue and sends the wake-up signal. From that point forward, all new calls to `CacheMap.get()` for that session return `None`. Physical removal from the map and cascading cleanup of owned transactions and cursors are deferred to the background task.

This means there is no race between concurrent lookups and eviction: the transition from `Active` to `EvictionRequested` is a single atomic timestamp write, and `CacheMap.get()` observes it on the next access. Any component that obtained a reference *before* the transition may continue holding it — the `Arc` keeps the value alive — but it will not be refreshed or re-acquired. This is the "any component already holding a live reference may continue to use it until it is `FullyDropped`" guarantee.

#### Cleanup Architecture

The `ServiceContext` background task owns references to all three stores and drives eviction entirely on its own. The stores do not reference each other. Eviction paths never perform cleanup inline; instead they push the item onto a cleanup queue and send a non-blocking wake-up signal to the cleanup task.

**Wake-up signal**

A bounded `mpsc` channel with capacity 1 is used as the wake-up signal. When an eviction is enqueued, the eviction path does a non-blocking `try_send(())`. If a signal is already pending, the send is silently dropped. This prevents unbounded signal buildup while still guaranteeing the cleanup task will wake soon.

**Cleanup loop**

After waking on a signal, the cleanup task applies a short debounce window (10–50 ms) to let nearby eviction requests accumulate, then drains any duplicate signals and runs one cleanup pass. A slower periodic fallback timer also ticks independently, so the system remains self-healing if a signal is ever missed. This hybrid model keeps latency low under normal load and prevents thrashing under bursts of expirations.

The cleanup task drains the cleanup queue iteratively (never recursively), breadth-first. When it removes a session it pushes the session's owned transaction and cursor IDs back onto the work queue; when it removes a transaction it pushes its cursor IDs. All three stores are processed in a single loop:

```mermaid
graph TD
    SC[ServiceContext background task]
    SC -->|removes expired entries from| SS[InMemorySessionStore]
    SC -->|removes expired entries from| TS[TransactionStore]
    SC -->|removes expired entries from| CS[CursorStore]
    SC -->|pushes child IDs onto work queue when parent is removed| SC
```

Child stores never reference parent stores. Cascading cleanup is the cleanup task's responsibility, not the stores'. Duplicate eviction requests are safe; removal is idempotent. Parent stores may temporarily retain stale child IDs, which are tolerated and lazily compacted on the next cleanup pass.

#### Session Limits

The number of active sessions is capped at `maxLogicalSessions` (default 1,000,000). When the cap is reached, `startSession` (and implicit session creation) returns an error to the client rather than silently evicting an existing session. Telemetry will be emitted when session creation is rejected due to the cap.

LRU eviction was considered as an alternative: silently remove the least-recently-used session to make room. It was rejected because an LRU victim may have an active transaction or open cursors, causing an in-progress operation to fail with no warning to the client that issued it. An explicit error at session creation is a predictable, recoverable signal; silent mid-flight abort is not. Operators who hit the cap should increase `maxLogicalSessions` or investigate session leaks.

### API Changes

The following gateway commands will be added or modified:

| Command | Status | Behavior |
|---|---|---|
| `startSession` | New | Creates a `LogicalSession` entry in `InMemorySessionStore` and returns the assigned `SessionId`. Supports both explicit and implicit session creation. |
| `refreshSessions` | New | Resets the TTL of the specified session(s). Does not refresh associated cursors or transactions. Tracked in [#425](https://github.com/documentdb/documentdb/issues/425). |
| `endSessions` | Modified | Marks the specified session(s) as expired. The session is not immediately removed; the `ServiceContext` cleanup task processes the eviction asynchronously and cascades cleanup to owned transactions and cursors. |
| `killSessions` | Existing | Immediately removes the specified session(s) and enqueues cascading cleanup of all owned transactions and cursors. |
| `killAllSessions` | Existing | Immediately removes all active sessions and enqueues cascading cleanup of all owned resources. |

**Breaking changes:** None. Implicit session handling (commands that carry a session ID without a prior `startSession`) continues to be supported. A `LogicalSession` is created on first use if one does not already exist.

### Database Schema Changes
*Not applicable*

### Configuration Changes

The following settings will be introduced:

| Setting | Type | Default | Description |
|---|---|---|---|
| `logicalSessionTimeoutInSeconds` | `int` | `1800` | Maximum number of seconds a session remains valid without being used or refreshed. |
| `maxLogicalSessions` | `int` | `1000000` | Maximum number of concurrently active sessions. When the cap is reached, new session creation fails with an error. |
| `useSessionBoundCursorLifetime` | `bool` | `false` | When enabled, cursor lifetime snaps to the session lifetime regardless of cursor type. `refreshSessions` refreshes all associated cursor lifetimes simultaneously. When disabled (default), cursor and session lifetimes are independent: cursors expire naturally unless actively used via `getMore`. Transaction-bound cursors always share the owning transaction's lifetime regardless of this setting. |
| `resourceCleanupIntervalInSeconds` | `int` | `60` | Interval at which the background cleanup task scans stores for expired sessions, transactions, and cursors. Explicit cleanup triggers an immediate pass with a minimum 5-second debounce between invocations. |

### Testing Strategy

*Describe how this will be tested*
- Unit test approach
- Integration test requirements
- Compatibility test requirements
- Performance test plans
- Migration test strategy

### Migration Path
*Not applicable*

### Documentation Updates

*What documentation needs to change?*
- User-facing docs
- Developer guides
- API references
- Examples/tutorials

---

## Implementation Tracking

*This section SHALL be populated during the Implementation phase.*

**Purpose:** Track the implementation progress of this RFC.

**Complete this section when:** Your RFC has been accepted and implementation work begins.

**Guidance:**
- Link to the PRs that implement this RFC. Update as implementation progresses.
- Provide success metrics.

### Implementation PRs

- [x] [PR #552: [OSS][GW] Uniform Identifiers for Session, Transaction and Cursor](https://github.com/documentdb/documentdb/pull/552/commits/f2eb1abfcd76b42cbc71ac3126ef5ab3bad34ebb)

### Status Updates

*Add dated status updates as implementation progresses*

**YYYY-MM-DD:** Initial implementation started in PR #XXX

**YYYY-MM-DD:** [Update on progress, blockers, or changes]

### Open Questions

*Track unresolved questions that arise during implementation*

- [x] **Question [2026-04-06]:** `Vec<CursorId>` vs `HashSet` vs `HashMap` for `LogicalSession.cursors` — **Resolved**, see Implementation Notes.

- [x] **Question [2026-04-06]:** How much stale `CursorId` growth is expected before compaction kicks in, and does it warrant a per-session cap? — **Resolved**, see Implementation Notes.

- [x] **Question [2026-04-06]:** Could the single cleanup worker become a bottleneck under high session drop rates (e.g. connection pool churn)? — **Resolved**, see Implementation Notes.

- [x] **Question [2026-04-06]:** When `maxLogicalSessions` is hit, what happens to a session with an active transaction if LRU eviction is used? — **Resolved**: LRU eviction was rejected; session creation fails with an explicit error instead. See Session Limits.

- [x] **Question [2026-04-06]:** How is `EvictionRequested` represented if there is no explicit state enum? Could concurrent lookups race with eviction? — **Resolved**: `EvictionRequested` is the TTL-expired state; explicit eviction atomically writes `u64::MIN` to the expiry timestamp. See Session Lifecycle.

- [x] **Question [2026-04-06]:** How are transaction-scoped cursors owned and cleaned up under the new three-store model? — **Resolved**, see Implementation Notes.

- [x] **Question [2026-04-06]:** When `useSessionBoundCursorLifetime` is enabled, does `refreshSessions` reset all owned cursor timeouts simultaneously, and what TTL does each cursor receive? — **Resolved**, see Implementation Notes.

### Implementation Notes

- **Decision [2026-04-01]:** Cursor timeout will not be refreshed when `refreshSessions` is called unless a configuration value, `useSessionBoundCursorLifetime` is set to true.
  - **Context:** Cursors currently consume a backend connection, tying the lifetime of the cursor to the session could lead to accidentally exhausting backend resources.
  - **Alternatives:** 
    - Decoupling completely without the ability to tie the lifetimes together
    - Binding cursor lifetime to a session lifetime.

- **Decision [2026-03-24]:** DashMap will be removed in favor of papaya::HashMap
  - **Context:** DashMap introduces additional contention with concurrent readers when iterating over and removing elements. This is observed even while iterating using shards with the `raw-api` featuer enabled.
  - **Alternatives:** 
    - Keep DashMap
    - Implement a custom data structure at the cost of additonal maintenance

- **Decision [2026-04-06]:** `LogicalSession.cursors` will use `HashSet<CursorId>` instead of `Vec<CursorId>`
  - **Context:** Removing a cursor from a `Vec` on kill or expiry requires a linear scan. `HashSet` provides O(1) removal with equivalent insertion and iteration cost. `CursorId` wraps a `u64`, making its `Hash`/`Eq` impls trivially cheap.
  - **Alternatives:**
    - `Vec<CursorId>`: O(n) removal - rejected as inconsistent with the O(k) cleanup guarantee in success metric #3.
    - `HashMap<CursorId, CursorMetadata>`: deferred until a concrete session-layer read pattern requiring per-cursor metadata without a `CursorStore` lookup is identified. Premature metadata fields risk staleness divergence from `CursorStoreEntry`.

- **Decision [2026-04-06]:** The inline `CursorStore` on `GatewayTransaction` will be eliminated
  - **Context:** All cursors — regardless of binding (global, transaction-bound, or session-bound) — will be registered in the main `CursorStore`. `CursorStoreEntry` will gain an optional `transaction_id: Option<TransactionId>` binding field alongside the existing `session_id`. The `cursors: CursorStore` field on `GatewayTransaction` will be removed. This means: transaction cleanup correctly pushes cursor IDs onto the work queue (consistent with the cleanup graph); `getMore` resolves cursors from the global store and validates the binding; ownership checks are uniform across all cursor types.
  - **Alternatives:**
    - Keep the inline store: implicit drop on transaction removal, no IDs to push — rejected as inconsistent with the three-store model and the cleanup graph description.

- **Decision [2026-04-06]:** `LogicalSession.cursors` and `transaction_id` are cleanup hints, not liveness records
  - **Context:** Cursors can be evicted globally (by TTL or `killCursors`) independently of their owning session. Rather than maintaining a back-reference from each cursor to its session (which would violate the top-down-only cleanup graph), stale IDs are tolerated in the session's set. Idempotent removal in `CursorStore` and `TransactionStore` makes stale IDs safe no-ops during session cleanup.
  - **Alternatives:**
    - Inverted index in `CursorStore` (`HashMap<SessionId, HashSet<CursorId>>`): eliminates stale IDs but requires coordinated two-phase writes on every cursor eviction and adds a second index to a high-throughput store — rejected as complexity not justified by the benefit.

- **Decision [2026-04-06]:** Stale `CursorId` accumulation in `LogicalSession.cursors` is accepted without a per-session cap or active compaction pass
  - **Context:** Cursor eviction does not proactively notify the owning session. Stale IDs accumulate until session eviction. Growth is bounded at `session_lifetime / cursor_ttl` per session: ~30 IDs (persisted, 60s TTL, 30-min session), ~3 IDs (streaming, 10-min TTL). At 8 bytes per `u64`, this is ~240 bytes per session at worst. `HashSet::remove` on an absent key is a single hash probe — free at cleanup time.
  - **Alternatives:**
    - Per-session liveness probe on insert (cap + `CursorStore.get()` per insert): adds overhead on a hot path to solve a sub-kilobyte memory problem — rejected.
    - Active-session compaction pass: O(total cursor IDs across all live sessions) probe work per interval — rejected as worse than the problem.
    - If high-cursor-churn-per-long-lived-session workloads emerge in practice, a per-session cap should be revisited.

- **Decision [2026-04-06]:** `useSessionBoundCursorLifetime` snaps cursor lifetime to session lifetime and refreshes all cursors on `refreshSessions`
  - **Context:** When enabled, cursor lifetime is no longer independent — it tracks the session lifetime regardless of cursor type (persisted or streaming). Calling `refreshSessions` resets all associated cursor lifetimes simultaneously to the session's new deadline. This is a known and accepted consequence of the flag: operators enabling it explicitly accept that backend connections may be held alive as long as the session is active and being refreshed. Transaction-bound cursors always share the owning transaction's lifetime regardless of this setting — their lifetime is governed by the transaction, not the session.
  - When disabled (default): cursor and session lifetimes are fully independent. Cursors expire naturally via their own TTL unless kept alive by `getMore`. This prevents resource exhaustion from indefinitely refreshed sessions inadvertently pinning backend connections.
  - **Alternatives:**
    - Resetting each cursor to its own full TTL on `refreshSessions`: rejected — inconsistent behavior between cursor types and harder to reason about at the session layer.
    - Not providing this flag at all: rejected — some operator workloads require long-running cursors tied explicitly to session lifetime.

- **Decision [2026-04-06]:** The cleanup task uses a single worker; multiple workers are not needed
  - **Context:** Cleanup operations are in-memory removes on `papaya::HashMap` — nanosecond-scale, not I/O-bound. The debounced batching model processes bursts efficiently in a single loop pass. `papaya::HashMap` supports concurrent writers without a global lock, so parallel workers would not reduce contention meaningfully. If profiling ever identified the cleanup task as a bottleneck, parallelising the work queue drain would be the first lever, but this is not anticipated.
  - **Alternatives:**
    - Multiple cleanup workers: adds coordination overhead (shared work queue, concurrent map removes) with no expected throughput benefit for in-memory operations — deferred unless profiling indicates otherwise.
