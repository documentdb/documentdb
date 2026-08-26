---
rfc: 0009
title: "Pluggable Authentication Architecture"
status: Draft
owner: "@straatsb"
issue: "TBD"
discussion: "TBD"
version-target: 1.0
implementations: []
---

# RFC-0009: Pluggable Authentication Architecture

## Problem

The DocumentDB PostgreSQL gateway currently has authentication logic tightly coupled to specific mechanisms (SCRAM-SHA-256 and MONGODB-OIDC). This creates friction for contributors and cloud providers who want to add new authentication methods.

### Impact on Contributors

Contributors face three barriers when adding authentication mechanisms:

1. **Core modification requirement**: Adding a new authentication method requires modifying the core `auth.rs` file, increasing the risk of breaking existing authentication flows
2. **No clear extension point**: There's no defined interface or pattern for adding authentication providers
3. **Testing complexity**: Changes to authentication logic require testing all existing mechanisms to ensure no regressions

### Impact on Cloud Providers

Cloud providers (AWS, Azure, GCP, and others) experience four challenges:

1. **Vendor lock-in concerns**: Authentication code for different cloud providers lives in the same core module, creating dependencies between unrelated providers
2. **Independent development barriers**: Cloud providers cannot develop and maintain their authentication implementations independently
3. **Deployment coupling**: Updates to one provider's authentication require redeploying code that affects all providers
4. **Configuration inflexibility**: No standardized way to enable/disable specific authentication mechanisms per deployment

### Impact on the Community

The community lacks:

1. **Extensibility**: No clear path for organizations to implement custom authentication mechanisms (LDAP, SAML, custom enterprise auth)
2. **Transparency**: Authentication logic is scattered across the codebase rather than organized by provider
3. **Modularity**: Cannot easily understand or test individual authentication mechanisms in isolation

### Current State

Authentication currently flows through a monolithic handler in `pg_documentdb_gw/src/auth.rs`:

```rust
// Current approach: hardcoded mechanism checks
async fn handle_sasl_start(...) -> Result<Response> {
    let mechanism = request.document().get_str("mechanism")?;
    
    match mechanism {
        "SCRAM-SHA-256" => handle_scram(...),
        "MONGODB-OIDC" => handle_oidc(...),
        _ => Err(unsupported_mechanism_error())
    }
}
```

This approach:
- Requires modifying the match statement for each new mechanism
- Couples all authentication logic together
- Makes it difficult to enable/disable mechanisms per deployment
- Prevents independent testing of authentication providers

### Success Criteria

A successful solution MUST achieve:

1. **Zero-modification extensibility**: Adding a new authentication mechanism requires no changes to core authentication routing logic
2. **Provider independence**: Each authentication provider can be developed, tested, and deployed independently
3. **Backward compatibility**: Existing SCRAM-SHA-256 and MONGODB-OIDC authentication continues working without changes
4. **Configuration flexibility**: Administrators can enable/disable authentication mechanisms via configuration
5. **Cloud-agnostic core**: Core authentication logic has no dependencies on specific cloud providers

### Non-Goals

This RFC explicitly does NOT:

- Mandate specific authentication mechanisms (providers are pluggable)
- Change the MongoDB wire protocol or SASL authentication flow
- Require database schema changes
- Modify the PostgreSQL authentication system
- Implement specific cloud provider authentication (those are separate implementations)

---

## Approach

### Solution Overview

Implement a trait-based authentication provider architecture using Rust's type system. Each authentication mechanism becomes a self-contained provider that implements a common `AuthProvider` trait. A central registry routes authentication requests to the appropriate provider based on the SASL mechanism name.

### Core Components

**1. AuthProvider Trait**
- Cloud-agnostic interface that all authentication providers implement
- Supports diverse authentication patterns: credential-based, token-based, certificate-based, multi-step handshakes
- Providers control their own initialization, state management, and cleanup

**2. AuthProviderRegistry**
- Central registry for provider discovery and routing
- Maps SASL mechanism names to provider implementations
- Provides O(1) lookup for authentication requests

**3. Provider Implementations**
- **ScramProvider**: Refactored SCRAM-SHA-256 logic (existing mechanism)
- **OidcProvider**: Refactored MONGODB-OIDC logic (existing mechanism)
- **Future providers**: Cloud-specific, enterprise, or custom authentication

**4. Configuration System**
- Enable/disable providers via configuration
- Provider-specific configuration (isolated from other providers)

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     MongoDB Client                          │
└────────────────────┬────────────────────────────────────────┘
                     │ SASL Request (mechanism: "SCRAM-SHA-256")
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              Gateway Auth Handler (auth.rs)                 │
│  - Extract mechanism name from request                      │
│  - Route to registry                                        │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│           AuthProviderRegistry (registry.rs)                │
│  - HashMap<String, Arc<dyn AuthProvider>>                   │
│  - get_provider(mechanism) -> Provider                      │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │  SCRAM  │  │  OIDC   │  │ Custom  │
   │Provider │  │Provider │  │Provider │
   └─────────┘  └─────────┘  └─────────┘
```

### Key Benefits

**1. Extensibility Without Core Changes**
- New authentication mechanisms register themselves with the registry
- No modifications to routing logic required

**2. Provider Independence**
- Each provider is self-contained with its own dependencies
- Cloud providers can maintain their authentication code independently
- Providers can be tested in isolation

**3. Configuration Flexibility**
- Enable/disable mechanisms per deployment
- Provider-specific configuration isolated from core

**4. Backward Compatibility**
- Existing authentication flows remain unchanged
- SCRAM and OIDC logic refactored into providers (no behavior changes)
- Default configuration enables existing mechanisms automatically

### Design Rationale

**Trait-Based Architecture**
- Leverages Rust's type system for compile-time safety
- Enables polymorphism without runtime overhead
- Provides clear contract for provider implementations

**Registry Pattern**
- Centralized provider management
- Providers resolved by mechanism name during authentication
- Supports configuration-based provider enable/disable

**Cloud-Agnostic Core**
- Core authentication logic has no cloud-specific dependencies
- Cloud providers can add authentication mechanisms independently without modifying core code

### Tradeoffs

**Abstraction Overhead**
- *Benefit:* Clean separation of concerns, extensibility
- *Cost:* Additional indirection through trait dispatch
- *Mitigation:* Minimal performance impact

**Refactoring Existing Code**
- *Benefit:* Cleaner architecture, easier to maintain
- *Cost:* Risk of introducing regressions in existing auth
- *Mitigation:* Comprehensive test suite, phased rollout, backward compatibility guarantees

**Configuration Complexity**
- *Benefit:* Fine-grained control over authentication mechanisms
- *Cost:* More configuration options to understand
- *Mitigation:* Sensible defaults (existing mechanisms enabled), clear documentation

### Alternatives Considered

**1. Plugin System with Dynamic Loading**
- Load authentication providers as dynamic libraries (.so/.dll files)
- *Rejected because:* Adds complexity, security risks, and deployment challenges. Compiled-in providers are simpler and safer.

**2. Macro-Based Code Generation**
- Use Rust macros to generate provider registration code
- *Rejected because:* Less explicit, harder to debug, doesn't solve the core extensibility problem.

**3. Keep Monolithic Handler with Better Organization**
- Reorganize existing code into modules but keep match-based routing
- *Rejected because:* Doesn't achieve zero-modification extensibility goal. Still requires core changes for new mechanisms.

**4. Separate Authentication Service**
- Extract all auth to a separate microservice
- *Rejected because:* Adds latency, operational complexity, and doesn't align with gateway architecture.

### Performance Considerations

**Trait Dispatch Overhead:**
- Dynamic dispatch via `dyn AuthProvider` adds minimal overhead (typically 1-2ns per call in Rust)
- Expected impact: Negligible compared to authentication operations (network I/O, crypto)
- Mitigated by: Caching provider references in Arc for zero-cost cloning

**Registry Lookup:**
- HashMap lookup is O(1) with minimal overhead
- Replaces match statement which is also O(1) but with branch prediction
- Expected net impact: Negligible

**Memory Overhead:**
- Each provider: Small fixed overhead (trait object + Arc wrapper)
- Registry: Minimal memory footprint for typical deployment (2-3 providers)
- Per-connection state: Varies by provider, size-limited to prevent exhaustion

**Concurrency:**
- Registry is read-only after initialization (no lock contention)
- Providers are Arc-wrapped for efficient concurrent access
- No expected performance degradation under high concurrency

**Validation:** Performance impacts will be measured during Phase 1 implementation against existing monolithic implementation. Target: < 1% regression in P95 authentication latency. Actual measurements will be documented in implementation PRs.

### Security Model

Providers are trusted code compiled into the gateway binary and run with full gateway privileges. Only first-party (core team) and vetted cloud provider implementations are supported. Custom providers must pass code review before merging. Providers should only access their own state within ConnectionContext, enforced through code review and documentation rather than sandboxing. Untrusted third-party providers are explicitly out of scope.

Providers must not persist credentials to disk. Providers may forward credentials to external services for validation (e.g., OIDC token verification). Credential memory handling follows existing gateway patterns.

### DocumentDB Integration

This architecture integrates with DocumentDB's existing components:

**pg_documentdb_gw (Gateway)**
- Primary integration point
- Refactor `auth.rs` to use registry pattern
- Add provider trait and registry modules

**ServiceContext**
- Add `auth_provider_registry` field
- Initialize registry with configured providers
- Provide registry access to connection handlers

**Configuration System**
- Extend setup configuration to support provider configuration
- Support per-provider configuration sections

---

## Implementation Phases

This RFC is implemented in three phases: a core refactor, basic resilience features, and advanced resilience & security features.

### Phase 1: Core Refactor (No Breaking Changes)

Phase 1 establishes the pluggable architecture by refactoring existing authentication into the trait-based system. No new business logic or resilience features are added.

**Goals:**
- Extract existing SCRAM and OIDC logic into provider implementations
- Introduce `AuthProvider` trait and `AuthProviderRegistry`
- Update auth handler to route through registry
- Maintain 100% backward compatibility

**Components:**
- **AuthProvider trait**: Core interface with `mechanism_name()`, `handle_sasl_start()`, `handle_sasl_continue()`, `supports_continue()`, `initialize()`, `shutdown()`, `on_connection_close()`
- **AuthProviderRegistry**: HashMap-based provider lookup with O(1) access
- **ScramProvider**: Refactored SCRAM-SHA-256 implementation
- **OidcProvider**: Refactored MONGODB-OIDC implementation
- **Modified auth handler**: Registry-based routing instead of match statements
- **Hello command integration**: Update `hello`/`isMaster` to query registry for enabled mechanisms instead of hardcoded list
- **Audit logging**: Standardized auth event logging (user, mechanism, success/failure, timestamp, source IP) in auth handler

**Success Criteria:**
- All existing tests pass
- No behavior changes in authentication flows
- Performance metrics unchanged
- Zero customer impact

---

### Phase 2: Basic Resilience

Phase 2 adds foundational resilience features to protect the gateway from slow or failing authentication providers.

**Goals:**
- Prevent slow external auth from blocking the gateway indefinitely
- Limit resource consumption per provider
- Provide basic observability into authentication performance

**Components:**
- **Timeout enforcement**: Per-provider configurable timeouts (auth handler wraps provider calls)
- **Resource isolation**: Per-provider concurrency limits (registry enforces limits)
- **Configuration system**: Per-provider resilience settings (timeout, concurrency limits)
- **Basic metrics**: Authentication success/failure/latency tagged by provider

**Success Criteria:**
- Authentication requests don't block indefinitely
- One provider cannot exhaust gateway resources
- Observable authentication performance per provider

---

### Phase 3: Advanced Resilience & Security

Phase 3 adds advanced resilience patterns and security hardening features.

**Goals:**
- Automatic failure detection and recovery for external auth providers
- Prevent timing-based attacks
- Support MongoDB-compatible per-user mechanism filtering

**Components:**
- **Circuit breakers**: Automatic failure detection and recovery (registry tracks state per provider)
- **Health checks**: Periodic provider health monitoring (background task calls `health_check()`)
- **Fallback behavior**: Configurable responses when circuit breakers trip
- **Timing attack mitigation**: Per-provider minimum authentication time to prevent username enumeration
- **Per-user mechanism filtering**: Support `hello` command with username parameter
- **Advanced metrics**: Circuit breaker state, health status, timing metrics

**Success Criteria:**
- Circuit breakers prevent cascading failures
- Gateway remains responsive under auth provider degradation
- Timing attacks are mitigated
- Per-user mechanism discovery works correctly

---

## Detailed Design

### AuthProvider Trait

The core abstraction that all authentication providers must implement. This trait defines the contract for authentication mechanisms.

**Phase Breakdown:**
- **Phase 1**: Core methods (`mechanism_name`, `handle_sasl_start`, `handle_sasl_continue`, `supports_continue`, `initialize`, `shutdown`, `on_connection_close`)
- **Phase 2**: Basic resilience method (`timeout`)
- **Phase 3**: Advanced resilience method (`health_check`)

**Complete Trait Definition:**

```rust
#[async_trait]
pub trait AuthProvider: Send + Sync {
    // ===== Identification =====
    
    /// Returns the SASL mechanism name (e.g., "SCRAM-SHA-256", "MONGODB-OIDC")
    /// Called by: Registry during registration
    fn mechanism_name(&self) -> &str;
    
    /// Returns true if this provider requires multi-step authentication
    /// Called by: Auth handler before routing saslContinue requests
    /// Default: false (single-step auth like OIDC)
    fn supports_continue(&self) -> bool {
        false
    }
    
    // ===== Authentication =====
    
    /// Handles the initial SASL authentication request (saslStart command)
    /// Called by: Auth handler when client sends saslStart
    /// Responsibility: Parse payload, validate credentials, return response with done flag
    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response>;
    
    /// Handles subsequent SASL authentication requests (saslContinue command)
    /// Called by: Auth handler when client sends saslContinue (only if supports_continue() is true)
    /// Responsibility: Continue multi-step auth, return response with done flag
    async fn handle_sasl_continue(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response>;
    
    // ===== Lifecycle =====
    
    /// Called once during provider registration
    /// Called by: Registry during provider registration
    /// Responsibility: Validate config, establish connection pools, initialize shared resources
    /// Failure: Provider is not registered, gateway continues without it
    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()>;
    
    /// Called once during graceful gateway shutdown
    /// Called by: Registry during shutdown
    /// Responsibility: Close connections, flush buffers, release resources
    /// Timeout: 30 seconds, then force shutdown
    async fn shutdown(&mut self) -> Result<()> {
        Ok(())  // Default: no cleanup needed
    }
    
    /// Called when a connection closes (success, failure, timeout, or disconnect)
    /// Called by: Connection handler on connection close
    /// Responsibility: Clean up per-connection state stored in ConnectionContext
    /// Default: No cleanup needed (most providers don't need this)
    async fn on_connection_close(&self, connection_context: &ConnectionContext) -> Result<()> {
        Ok(())
    }
    
    // ===== Resilience (Phase 2 & 3) =====
    
    /// Returns the configured timeout for authentication attempts
    /// Called by: Auth handler before calling handle_sasl_start/continue
    /// Usage: Auth handler wraps provider calls with timeout enforcement
    /// Default: None (no timeout)
    fn timeout(&self) -> Option<Duration> {
        None
    }
    
    /// Performs a health check for this provider
    /// Called by: Background task periodically (e.g., every 60 seconds)
    /// Responsibility: Check if provider can reach external services, return health status
    /// Usage: Circuit breaker uses health status to determine if provider is available
    /// Default: Always healthy (for local auth like SCRAM)
    async fn health_check(&self) -> HealthStatus {
        HealthStatus::Healthy
    }
}
```

**Provider Lifecycle:**

```
Gateway Lifecycle:
  1. Create provider instance
  2. Call initialize(config) → Success: register in registry, Failure: skip provider
  3. Provider is ready to handle auth requests

Per Connection:
  4. Client connects → (optional) provider can track connection state
  5. Client sends saslStart → handle_sasl_start() called
  6. [Multi-step only] Client sends saslContinue → handle_sasl_continue() called
  7. Connection closes → on_connection_close() called

Background (Phase 2):
  8. Periodic health checks → health_check() called every 60s

Gateway Shutdown:
  9. Call shutdown() on all providers (30s timeout)
  10. Force shutdown if timeout expires
```

**Authentication Patterns:**

- **Single-step** (OIDC): `saslStart` → `done: true` → complete
- **Multi-step** (SCRAM): `saslStart` → `done: false` → `saslContinue` → `done: true` → complete
- **Multi-round** (Kerberos): `saslStart` → `done: false` → `saslContinue` → `done: false` → `saslContinue` → `done: true` → complete

**Error Handling:**

Providers return `Result<Response>` using the existing `DocumentDBError` type:

- `authentication_failed(msg)` - Invalid credentials, unsupported mechanism, token validation failures
- `internal_error(msg)` - Provider bugs, unexpected states, configuration errors
- `bad_value(msg)` - Malformed payloads, invalid request format
- `unauthorized(msg)` - Commands that require authentication

**Error Message Format:** Include provider name for debugging: `"SCRAM-SHA-256: Invalid password"`

**Phase 2 Resilience Features:**

- **Panic Handling:** Gateway wraps provider calls with panic catching. Panics are converted to `internal_error`, the provider is marked unhealthy, and other providers continue operating.
- **Timeout Enforcement:** Gateway enforces per-provider timeouts. Providers that exceed timeout are cancelled and return `authentication_failed("Authentication timeout")`.
- **Retryability:** Circuit breaker determines retry behavior based on error patterns. Providers don't need to distinguish retryable vs permanent failures.

**State Management:**

Multi-step authentication (e.g., SCRAM) requires storing state between `saslStart` and `saslContinue` calls. Providers store per-connection state in ConnectionContext:

- **Storage**: Providers use ConnectionContext to store state keyed by provider name
- **Isolation**: Each provider's state is isolated from other providers
- **Size limits**: State storage has reasonable size limits to prevent memory exhaustion attacks
- **Cleanup**: State is automatically cleaned up on connection close via `on_connection_close()` callback
- **Timeout cleanup**: State is cleaned up if authentication doesn't complete within configured timeout
- **No global state**: Providers should not use static or global variables for connection state

**Supporting Types:**

```rust
pub struct ProviderConfig {
    pub enabled: bool,
    pub timeout_ms: Option<u64>,
    pub min_auth_time_ms: Option<u64>,  // Phase 3: Timing attack mitigation
    pub max_concurrent: Option<usize>,
    pub circuit_breaker: Option<CircuitBreakerConfig>,
    pub health_check: Option<HealthCheckConfig>,
    pub custom: serde_json::Value,  // Provider-specific config
}

pub enum HealthStatus {
    Healthy,
    Degraded { reason: String },
    Unhealthy { reason: String },
}
```

### AuthProviderRegistry

Central registry for managing authentication providers.

**Phase Breakdown:**
- **Phase 1**: Core registry (provider registration, lookup, validation)
- **Phase 2**: Concurrency limit enforcement
- **Phase 3**: Circuit breaker state tracking, fallback logic

**Core Functionality:**

```rust
struct AuthProviderRegistry {
    providers: HashMap<String, Arc<dyn AuthProvider>>
}

impl AuthProviderRegistry {
    fn register(&mut self, provider: Box<dyn AuthProvider>) -> Result<()>;
    fn get_provider(&self, mechanism: &str) -> Result<Arc<dyn AuthProvider>>;
    fn is_supported(&self, mechanism: &str) -> bool;
}
```

**Design Characteristics:**

- **O(1) lookup**: HashMap provides constant-time provider lookup
- **Duplicate prevention**: Rejects registration of duplicate mechanism names
- **Initialization**: Calls provider `initialize()` during registration

**Registry Behavior:**

1. **Registration**: Providers register themselves with their mechanism name
2. **Lookup**: Authentication requests query the registry by mechanism name
3. **Validation**: Registry ensures no duplicate mechanisms are registered
4. **Error handling**: Returns clear errors for unsupported mechanisms

**Sequence Diagram:**

```
Provider Registration:
  Gateway -> ScramProvider: new()
  Gateway -> Registry: register(ScramProvider)
  Registry -> ScramProvider: initialize()
  Registry -> HashMap: insert("SCRAM-SHA-256", ScramProvider)
  
  Gateway -> OidcProvider: new()
  Gateway -> Registry: register(OidcProvider)
  Registry -> OidcProvider: initialize()
  Registry -> HashMap: insert("MONGODB-OIDC", OidcProvider)

Auth Request (Success):
  Client -> Gateway: SASL request (mechanism: "SCRAM-SHA-256")
  Gateway -> Registry: get_provider("SCRAM-SHA-256")
  Registry -> HashMap: lookup("SCRAM-SHA-256")
  Registry -> Gateway: Arc<ScramProvider>
  Gateway -> ScramProvider: handle_sasl_start(...)
  ScramProvider -> Gateway: Response
  Gateway -> Client: Response

Auth Request (Error - Unsupported):
  Client -> Gateway: SASL request (mechanism: "PLAIN")
  Gateway -> Registry: get_provider("PLAIN")
  Registry -> HashMap: lookup("PLAIN")
  Registry -> Gateway: Error("Unsupported mechanism: PLAIN")
  Gateway -> Client: AuthenticationFailed error

Auth Request (Error - Invalid Credentials):
  Client -> Gateway: SASL request (mechanism: "SCRAM-SHA-256")
  Gateway -> Registry: get_provider("SCRAM-SHA-256")
  Registry -> Gateway: Arc<ScramProvider>
  Gateway -> ScramProvider: handle_sasl_start(...)
  ScramProvider -> Gateway: Error("Invalid credentials")
  Gateway -> Client: AuthenticationFailed error
```

### Modified Auth Handler

The main authentication handler is simplified to use the registry pattern.

**Current Implementation (Monolithic):**

```rust
async fn handle_sasl_start(...) -> Result<Response> {
    let mechanism = request.document().get_str("mechanism")?;
    
    match mechanism {
        "SCRAM-SHA-256" => handle_scram(...),
        "MONGODB-OIDC" => handle_oidc(...),
        _ => Err(unsupported_mechanism_error())
    }
}
```

**Proposed Implementation (Registry-Based):**

```rust
async fn handle_sasl_start(...) -> Result<Response> {
    let mechanism = request.document().get_str("mechanism")?;
    let registry = connection_context.service_context.auth_provider_registry();
    let provider = registry.get_provider(mechanism).await?;
    provider.handle_sasl_start(connection_context, request).await
}
```

**Key Changes:**

1. **No hardcoded mechanism checks**: Registry lookup replaces match statement
2. **Provider routing**: Providers are resolved by mechanism name during authentication
3. **Extensibility**: New mechanisms require no changes to this code
4. **Backward compatibility**: Existing mechanisms work through refactored providers
5. **Audit logging**: Auth handler logs all authentication attempts and results with standard fields (user, mechanism, success/failure, timestamp, source IP)

### Hello Command Integration

**Phase Breakdown:**
- **Phase 1**: Query registry for enabled mechanisms (replaces hardcoded list)
- **Phase 3**: Per-user mechanism filtering via `saslSupportedMechs` parameter

The MongoDB `hello` (and legacy `isMaster`) command returns server information including `saslSupportedMechs` - the list of supported authentication mechanisms.

**Current Implementation:**
```rust
"saslSupportedMechs": ["SCRAM-SHA-256"],  // Hardcoded
```

**Phase 1 Implementation:**
```rust
let mechanisms = registry.list_enabled_mechanisms();
"saslSupportedMechs": mechanisms,  // Dynamic from registry
```

**Phase 3 Enhancement:**
When the `hello` command includes a username parameter (`saslSupportedMechs: "admin.username"`), return only mechanisms available for that specific user by querying user database for supported mechanisms.

### Provider Implementation Pattern

Existing authentication mechanisms will be refactored into providers following this pattern.

**Example: SCRAM Provider Structure**

```rust
pub struct ScramProvider {
    config: ProviderConfig,
}

#[async_trait]
impl AuthProvider for ScramProvider {
    fn mechanism_name(&self) -> &str {
        "SCRAM-SHA-256"
    }
    
    fn supports_continue(&self) -> bool {
        true  // SCRAM requires multi-step handshake
    }
    
    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        // Parse client-first-message
        // Generate server nonce and salt
        // Store state in connection_context.auth_state
        // Return response with done: false
    }
    
    async fn handle_sasl_continue(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        // Retrieve state from connection_context.auth_state
        // Verify client proof
        // Complete authentication
        // Return response with done: true
    }
    
    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()> {
        self.config = config.clone();
        // Validate configuration
        Ok(())
    }
    
    async fn shutdown(&mut self) -> Result<()> {
        // SCRAM is local auth, no resources to clean up
        Ok(())
    }
    
    fn timeout(&self) -> Option<Duration> {
        self.config.timeout_ms.map(Duration::from_millis)
    }
    
    async fn health_check(&self) -> HealthStatus {
        // SCRAM is local auth, always healthy
        HealthStatus::Healthy
    }
}
```

**Example: OIDC Provider Structure**

```rust
pub struct OidcProvider {
    config: ProviderConfig,
    http_client: reqwest::Client,
}

#[async_trait]
impl AuthProvider for OidcProvider {
    fn mechanism_name(&self) -> &str {
        "MONGODB-OIDC"
    }
    
    fn supports_continue(&self) -> bool {
        false  // OIDC is single-step
    }
    
    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        // Extract JWT token from payload
        // Validate token with IdP
        // Return response with done: true
    }
    
    async fn handle_sasl_continue(
        &self,
        _connection_context: &mut ConnectionContext,
        _request: &Request<'_>,
    ) -> Result<Response> {
        // Never called because supports_continue() returns false
        unreachable!()
    }
    
    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()> {
        self.config = config.clone();
        self.http_client = reqwest::Client::new();
        // Validate IdP endpoint is reachable
        Ok(())
    }
    
    async fn shutdown(&mut self) -> Result<()> {
        // Close HTTP client connections
        Ok(())
    }
    
    fn timeout(&self) -> Option<Duration> {
        self.config.timeout_ms.map(Duration::from_millis)
    }
    
    async fn health_check(&self) -> HealthStatus {
        // Ping IdP endpoint
        match self.http_client.get(&self.config.idp_url).send().await {
            Ok(_) => HealthStatus::Healthy,
            Err(e) if e.is_timeout() => HealthStatus::Degraded { 
                reason: "IdP slow to respond".to_string() 
            },
            Err(_) => HealthStatus::Unhealthy { 
                reason: "Cannot reach IdP".to_string() 
            },
        }
    }
}
```
```

**Refactoring Strategy:**

1. **Extract logic**: Move existing authentication code into provider implementations
2. **Preserve behavior**: Ensure refactored providers produce identical results
3. **Maintain state**: Use existing connection context for state management
4. **No API changes**: External behavior remains unchanged

**Provider Examples:**

- **ScramProvider**: Multi-step credential-based authentication (existing)
- **OidcProvider**: Single-step token-based authentication (existing)
- **Future providers**: PLAIN, GSSAPI, IAM, certificate-based, etc.

### Configuration Changes

**Phase Breakdown:**
- **Phase 1**: Basic provider enable/disable configuration
- **Phase 2**: Timeout and concurrency limit settings
- **Phase 3**: Circuit breaker, health check, and timing attack mitigation settings

Extend setup configuration to support provider management and resilience features:

```json
{
  "authentication": {
    "providers": {
      "scram": {
        "enabled": true,
        "timeout_ms": 5000,
        "min_auth_time_ms": 100,
        "max_concurrent": 100
      },
      "oidc": {
        "enabled": true,
        "timeout_ms": 10000,
        "min_auth_time_ms": 200,
        "max_concurrent": 50,
        "circuit_breaker": {
          "failure_threshold": 5,
          "timeout_duration_ms": 30000,
          "half_open_max_attempts": 3
        },
        "health_check": {
          "enabled": true,
          "interval_ms": 60000
        }
      }
    }
  }
}
```

**Configuration Principles:**

1. **Per-provider configuration**: Each provider has its own configuration section
2. **Enable/disable control**: Administrators can selectively enable mechanisms
3. **Resilience settings**: Timeout, circuit breaker, and concurrency limits per provider
4. **Provider-specific settings**: Providers define their own configuration schema
5. **Sensible defaults**: Existing mechanisms (SCRAM, OIDC) enabled by default with reasonable timeout/limit values

**Configuration Loading:**

- Providers access configuration through an abstraction layer rather than directly accessing setup config structs
- Invalid configuration causes registration to fail
- Missing configuration sections use provider defaults

**Configuration Validation:**

- Timeout values must be positive integers
- Concurrency limits must be positive integers
- Circuit breaker thresholds must be positive integers
- Invalid values prevent provider registration and log clear error messages

### Testing Strategy

**Phase Breakdown:**
- **Phase 1**: Core functionality tests (registry, providers, auth handler, configuration)
- **Phase 2**: Basic resilience tests (timeouts, concurrency limits, basic metrics)
- **Phase 3**: Advanced resilience tests (circuit breakers, health checks, timing attack mitigation, per-user mechanisms)

**Unit Tests**

1. **AuthProviderRegistry Tests** (Phase 1)
   - Provider registration and lookup
   - Duplicate registration prevention
   - Unsupported mechanism error handling
   - Thread-safety under concurrent access

2. **Provider Tests** (Phase 1)
   - Each provider tested in isolation
   - Verify refactored logic maintains behavior
   - Test provider lifecycle (initialize, cleanup)
   - Mock external dependencies (databases, APIs)

3. **Basic Resilience Tests** (Phase 2)
   - Timeout enforcement per provider
   - Concurrency limit enforcement
   - Basic metrics collection

4. **Advanced Resilience Tests** (Phase 3)
   - Circuit breaker state transitions (closed → open → half-open → closed)
   - Health check execution and status reporting
   - Fallback behavior when circuit breaker trips
   - Timing attack mitigation

**Integration Tests**

1. **End-to-End Authentication** (Phase 1)
   - SCRAM authentication through registry
   - OIDC authentication through registry
   - Mechanism switching between connections
   - Concurrent connections with different mechanisms

2. **Configuration Tests** (Phase 1, 2 & 3)
   - Enabling/disabling providers (Phase 1)
   - Invalid configuration handling (Phase 1)
   - Default configuration behavior (Phase 1)
   - Timeout configuration validation (Phase 2)
   - Concurrency limit configuration validation (Phase 2)
   - Circuit breaker configuration validation (Phase 3)

3. **Basic Resilience Integration Tests** (Phase 2)
   - Timeout prevents indefinite blocking
   - Concurrency limits prevent thread pool exhaustion

4. **Advanced Resilience Integration Tests** (Phase 3)
   - Slow external auth provider doesn't block SCRAM users
   - Circuit breaker prevents cascading failures
   - Health checks detect and report unhealthy providers

**Property-Based Tests**

1. **Provider Registration Uniqueness** (Phase 1): For any two provider registration attempts with the same mechanism name, the second registration should fail
2. **Mechanism Routing Correctness** (Phase 1): For any registered provider and SASL request with that provider's mechanism name, the request should be routed to that specific provider
3. **Timeout Enforcement** (Phase 2): For any provider with configured timeout T, authentication requests that exceed T milliseconds should fail with timeout error
4. **Circuit Breaker Correctness** (Phase 3): For any provider with failure threshold N, after N consecutive failures, the circuit breaker should open and reject subsequent requests

**Regression Testing**

- Comprehensive test suite for existing SCRAM and OIDC authentication
- Verify refactored providers produce identical results to original implementation
- Performance benchmarks to ensure no regression
- Load testing to verify resilience under high concurrency

### Migration Path

**Database Schema Changes:**

No database schema changes are required for this RFC. All changes are at the application layer (gateway code).

**Phase 1: Core Refactor (No Breaking Changes)**

1. Create `AuthProvider` trait and `AuthProviderRegistry`
2. Extract SCRAM logic into `ScramProvider`
3. Extract OIDC logic into `OidcProvider`
4. Update auth handler to use registry
5. Update `hello`/`isMaster` command to query registry for enabled mechanisms
6. Add audit logging to auth handler
7. Register default providers (SCRAM, OIDC)
8. Run comprehensive test suite
9. Deploy to test environment

**Success Criteria for Phase 1:**
- All existing tests pass
- No behavior changes in authentication flows
- Performance metrics unchanged
- Zero customer impact

**Note:** Phase 1 providers implement the core trait methods (`mechanism_name`, `handle_sasl_start`, `handle_sasl_continue`, `supports_continue`, `initialize`, `shutdown`, `on_connection_close`). The resilience methods (`timeout`, `health_check`) use default implementations.

---

**Phase 2: Basic Resilience**

Phase 2 adds foundational resilience features to protect the gateway from slow or failing authentication providers.

1. **Per-provider timeout configuration**
   - Configurable timeout per provider (e.g., SCRAM: 5s, OIDC: 10s)
   - Prevents slow external services from blocking the gateway indefinitely
   - Timeout applies to entire authentication flow (start + continue)
   - Failed timeout attempts return authentication error to client
   - **Implementation**: Auth handler wraps provider calls with timeout enforcement using `provider.timeout()`

2. **Resource isolation**
   - Per-provider concurrency limits
   - Prevents thread pool exhaustion from one provider affecting others
   - Ensures one provider cannot exhaust gateway resources
   - Configurable max concurrent authentication attempts per provider
   - **Implementation**: Registry tracks active authentication attempts per provider

3. **Provider configuration system**
   - Per-provider configuration sections (timeout, concurrency limits)
   - Configuration validation
   - Invalid configuration prevents provider registration
   - **Implementation**: `ProviderConfig` struct passed to `initialize()` method

4. **Basic metrics and observability**
   - Authentication metrics (success/failure/latency) tagged by provider
   - Timeout metrics per provider
   - Concurrency metrics (active auth attempts per provider)
   - Metrics emitted by auth handler and registry (not individual providers) for consistency
   - Connection ID from ConnectionContext used for trace correlation across logs and metrics
   - **Implementation**: Registry and auth handler emit metrics at key points

**Success Criteria for Phase 2:**
- Authentication requests don't block indefinitely
- One provider cannot exhaust gateway resources
- Observable authentication performance per provider
- Configurable timeouts prevent indefinite blocking

---

**Phase 3: Advanced Resilience & Security**

Phase 3 adds advanced resilience patterns and security hardening features.

1. **Circuit breaker pattern**
   - Track failure rates per provider
   - Automatically stop calling failing external services
   - Configurable: failure threshold, timeout duration, half-open retry
   - Prevents wasting resources on calls that will fail
   - Circuit breaker state: closed (normal), open (failing), half-open (testing recovery)
   - **Implementation**: Registry maintains circuit breaker state per provider

2. **Provider health checks**
   - Periodic health check mechanism
   - Providers report health status via `health_check()` method
   - Unhealthy providers can be temporarily disabled
   - Health status exposed via metrics
   - **Implementation**: Background task periodically calls `provider.health_check()`

3. **Fallback behavior configuration**
   - Define behavior when circuit breaker trips
   - Options: immediate failure, queue for retry
   - Per-provider fallback policies
   - Graceful degradation when providers are unhealthy
   - **Implementation**: Registry applies fallback logic based on circuit breaker state

4. **Timing attack mitigation**
   - Per-provider minimum authentication time
   - Prevents username enumeration and timing-based credential attacks
   - Auth handler enforces minimum duration by adding delay if provider completes too quickly
   - Configurable per provider
   - Can be dynamically adjusted based on observed authentication patterns
   - **Implementation**: Auth handler wraps provider calls with timing enforcement

5. **Per-user mechanism filtering**
   - Support `hello` command with `saslSupportedMechs` parameter containing username
   - Returns only authentication mechanisms available for that specific user
   - Queries user database to determine which mechanisms the user supports
   - Enables MongoDB-compatible per-user auth mechanism discovery
   - **Implementation**: Hello command handler queries registry and filters by user capabilities

6. **Advanced metrics**
   - Circuit breaker state metrics (open/closed/half-open)
   - Health check status per provider
   - Timing attack mitigation metrics
   - **Implementation**: Registry and auth handler emit metrics at key points

**Success Criteria for Phase 3:**
- Circuit breakers prevent cascading failures
- Gateway remains responsive under auth provider degradation
- Timing attacks are mitigated
- Per-user mechanism discovery works correctly
- Observable provider health and circuit breaker state

**Deployment Considerations:**

- Comprehensive test suite to validate each phase before release
- Performance benchmarks to ensure no regression
- Gradual rollout to production with monitoring
- Clear release notes documenting changes and new configuration options

**Rollback Strategy:**

- **Phase 1**: Can rollback to previous version as refactor maintains identical behavior. No configuration changes required.
- **Phase 2**: Can rollback by removing timeout/concurrency configuration. Existing auth continues to work without resilience features.
- **Phase 3**: Can rollback by disabling circuit breakers and health checks in configuration. Core auth functionality unaffected.
- **Configuration compatibility**: New configuration fields are optional with sensible defaults, allowing gradual adoption.

### Documentation Updates

**User-Facing Documentation**

- Overview of supported authentication mechanisms
- Configuration guide for authentication providers
- Examples for each authentication method
- Troubleshooting guide for authentication issues

**Developer Documentation**

- `AuthProvider` trait interface specification
- Guide for implementing custom providers
- Provider implementation checklist
- Testing requirements for providers
- Example provider implementation walkthrough

**API Documentation**

- Provider registration API
- Configuration format specification
- Error codes and messages
- Migration guide for existing deployments

**Documentation Principles:**

- Focus on concepts and patterns, not implementation details
- Provide examples for common use cases
- Keep documentation synchronized with code
- Include diagrams for architecture overview

---

## Implementation Tracking

### Success Metrics

**Phase 1:**
- Zero authentication failures during rollout
- No performance regression (P95 latency within 5% of baseline)
- 100% of existing tests passing

**Phase 2:**
- Authentication timeout rate < 0.1%
- No single provider consuming > 50% of auth threads
- Observable metrics for all providers

**Phase 3:**
- Circuit breaker prevents cascading failures (measured in chaos testing)
- Timing attack mitigation active for all providers
- Per-user mechanism filtering working for all auth types

### Phase 1 Implementation PRs

- [ ] PR #XXX: Create AuthProvider trait and AuthProviderRegistry
- [ ] PR #XXX: Refactor SCRAM authentication into ScramProvider
- [ ] PR #XXX: Refactor OIDC authentication into OidcProvider
- [ ] PR #XXX: Update auth handler to use registry
- [ ] PR #XXX: Add comprehensive test suite for refactored auth
- [ ] PR #XXX: Update documentation

### Phase 2 Implementation PRs

- [ ] PR #XXX: Add per-provider timeout configuration and enforcement
- [ ] PR #XXX: Add resource isolation (per-provider concurrency limits)
- [ ] PR #XXX: Implement provider configuration system for basic resilience
- [ ] PR #XXX: Add basic metrics and observability
- [ ] PR #XXX: Add basic resilience integration tests
- [ ] PR #XXX: Update documentation for timeout and concurrency configuration

### Phase 3 Implementation PRs

- [ ] PR #XXX: Implement circuit breaker pattern for providers
- [ ] PR #XXX: Implement provider health checks
- [ ] PR #XXX: Add fallback behavior configuration
- [ ] PR #XXX: Implement timing attack mitigation
- [ ] PR #XXX: Add per-user mechanism filtering for hello command
- [ ] PR #XXX: Add advanced metrics (circuit breaker state, health status)
- [ ] PR #XXX: Add advanced resilience and security integration tests
- [ ] PR #XXX: Update documentation for advanced resilience and security features

### Status Updates

*Status updates will be added as implementation progresses*

### Open Questions

**Staged Rollout Strategy:**

Should we implement a staged rollout process for deploying these changes? This would be phase-agnostic and apply to the release process for all phases:

- **Stage 1 (Dual Implementation)**: Deploy new pluggable architecture alongside existing monolithic code. Add a GUC (Grand Unified Configuration) flag to toggle between implementations, disabled by default (old implementation runs).
- **Stage 2 (Default Switch)**: Enable the GUC by default after validation period, making new implementation the default while keeping old code as fallback.
- **Stage 3 (Cleanup)**: Remove old monolithic code and GUC flag entirely once new implementation is proven stable.

**Considerations:**
- Provides safety net for rollback without redeployment
- Allows gradual confidence building in production
- Adds complexity of maintaining two implementations temporarily
- Requires careful testing of both code paths

**Alternative:** Direct cutover with standard deployment rollback if issues arise.

*Decision to be made before Phase 1 implementation begins.*

### Implementation Notes

*Implementation notes will be captured as work progresses*
