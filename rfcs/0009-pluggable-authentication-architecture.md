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
- Thread-safe with async support

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
- Providers can be added at compile-time or runtime

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
- Dynamic provider registration
- Supports runtime configuration changes

**Cloud-Agnostic Core**
- Core authentication logic has no cloud-specific dependencies
- Providers encapsulate cloud-specific logic
- Enables multi-cloud and hybrid deployments

### Tradeoffs

**Abstraction Overhead**
- *Benefit:* Clean separation of concerns, extensibility
- *Cost:* Additional indirection through trait dispatch
- *Mitigation:* Minimal performance impact (single trait call per auth request)

**Refactoring Existing Code**
- *Benefit:* Cleaner architecture, easier to maintain
- *Cost:* Risk of introducing regressions in existing auth
- *Mitigation:* Comprehensive test suite, phased rollout, backward compatibility guarantees

**Configuration Complexity**
- *Benefit:* Fine-grained control over authentication mechanisms
- *Cost:* More configuration options to understand
- *Mitigation:* Sensible defaults (existing mechanisms enabled), clear documentation

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

## Detailed Design

### AuthProvider Trait

The core abstraction that all authentication providers must implement. This trait defines the contract for authentication mechanisms.

**Key Methods:**

```rust
trait AuthProvider: Send + Sync {
    fn mechanism_name(&self) -> &str;
    async fn handle_sasl_start(...) -> Result<Response>;
    async fn handle_sasl_continue(...) -> Result<Response>;
    fn supports_continue(&self) -> bool;
    async fn initialize(&mut self) -> Result<()>;
    async fn cleanup(...) -> Result<()>;
}
```

**Design Characteristics:**

- **Cloud-agnostic**: No dependencies on specific cloud providers
- **Flexible**: Supports credential-based, token-based, certificate-based, and multi-step authentication patterns
- **Self-contained**: Each provider manages its own state, configuration, and resources
- **Async-first**: All I/O operations are asynchronous for performance

**Provider Responsibilities:**

1. **Mechanism identification**: Return the SASL mechanism name (e.g., "SCRAM-SHA-256", "MONGODB-OIDC")
2. **Request handling**: Parse authentication payloads and validate credentials
3. **State management**: Maintain per-connection authentication state
4. **Resource lifecycle**: Initialize resources on registration, cleanup on connection close
5. **Error handling**: Return appropriate authentication errors

### AuthProviderRegistry

Central registry for managing authentication providers.

**Core Functionality:**

```rust
struct AuthProviderRegistry {
    providers: HashMap<String, Arc<dyn AuthProvider>>
}

impl AuthProviderRegistry {
    async fn register(provider: Box<dyn AuthProvider>) -> Result<()>;
    async fn get_provider(mechanism: &str) -> Result<Arc<dyn AuthProvider>>;
    async fn is_supported(mechanism: &str) -> bool;
}
```

**Design Characteristics:**

- **Thread-safe**: Uses `RwLock` for concurrent access
- **O(1) lookup**: HashMap provides constant-time provider lookup
- **Duplicate prevention**: Rejects registration of duplicate mechanism names
- **Initialization**: Calls provider `initialize()` during registration

**Registry Behavior:**

1. **Registration**: Providers register themselves with their mechanism name
2. **Lookup**: Authentication requests query the registry by mechanism name
3. **Validation**: Registry ensures no duplicate mechanisms are registered
4. **Error handling**: Returns clear errors for unsupported mechanisms

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
2. **Dynamic routing**: Providers are resolved at runtime
3. **Extensibility**: New mechanisms require no changes to this code
4. **Backward compatibility**: Existing mechanisms work through refactored providers

### Provider Implementation Pattern

Existing authentication mechanisms will be refactored into providers following this pattern.

**Example: SCRAM Provider Structure**

```rust
struct ScramProvider {
    // Provider-specific state
}

impl AuthProvider for ScramProvider {
    fn mechanism_name(&self) -> &str {
        "SCRAM-SHA-256"
    }
    
    fn supports_continue(&self) -> bool {
        true  // SCRAM requires multi-step handshake
    }
    
    async fn handle_sasl_start(...) -> Result<Response> {
        // Extract existing SCRAM logic from auth.rs
        // Parse client-first-message
        // Generate server-first-message
        // Store state in connection context
    }
    
    async fn handle_sasl_continue(...) -> Result<Response> {
        // Extract existing SCRAM continue logic
        // Verify client proof
        // Complete authentication
    }
}
```

**Refactoring Strategy:**

1. **Extract logic**: Move existing authentication code into provider implementations
2. **Preserve behavior**: Ensure refactored providers produce identical results
3. **Maintain state**: Use existing connection context for state management
4. **No API changes**: External behavior remains unchanged

**Provider Examples:**

- **ScramProvider**: Multi-step credential-based authentication (existing)
- **OidcProvider**: Single-step token-based authentication (existing)
- **CustomProvider**: Future implementations by cloud providers or organizations

### Configuration Changes

Extend setup configuration to support provider management:

```json
{
  "authentication": {
    "providers": {
      "scram": {
        "enabled": true
      },
      "oidc": {
        "enabled": true
      }
    }
  }
}
```

**Configuration Principles:**

1. **Per-provider configuration**: Each provider has its own configuration section
2. **Enable/disable control**: Administrators can selectively enable mechanisms
3. **Provider-specific settings**: Providers define their own configuration schema
4. **Sensible defaults**: Existing mechanisms (SCRAM, OIDC) enabled by default

**Configuration Loading:**

- Providers load their configuration during `initialize()`
- Invalid configuration causes registration to fail
- Configuration errors logged at startup
- Missing configuration sections use provider defaults

### Testing Strategy

**Unit Tests**

1. **AuthProviderRegistry Tests**
   - Provider registration and lookup
   - Duplicate registration prevention
   - Unsupported mechanism error handling
   - Thread-safety under concurrent access

2. **Provider Tests**
   - Each provider tested in isolation
   - Verify refactored logic maintains behavior
   - Test provider lifecycle (initialize, cleanup)
   - Mock external dependencies (databases, APIs)

**Integration Tests**

1. **End-to-End Authentication**
   - SCRAM authentication through registry
   - OIDC authentication through registry
   - Mechanism switching between connections
   - Concurrent connections with different mechanisms

2. **Configuration Tests**
   - Enabling/disabling providers
   - Invalid configuration handling
   - Default configuration behavior

**Property-Based Tests**

1. **Provider Registration Uniqueness**: For any two provider registration attempts with the same mechanism name, the second registration should fail
2. **Mechanism Routing Correctness**: For any registered provider and SASL request with that provider's mechanism name, the request should be routed to that specific provider

**Regression Testing**

- Comprehensive test suite for existing SCRAM and OIDC authentication
- Verify refactored providers produce identical results to original implementation
- Performance benchmarks to ensure no regression

### Migration Path

**Phase 1: Refactor Existing Auth (No Breaking Changes)**

1. Create `AuthProvider` trait and `AuthProviderRegistry`
2. Extract SCRAM logic into `ScramProvider`
3. Extract OIDC logic into `OidcProvider`
4. Update auth handler to use registry
5. Register default providers (SCRAM, OIDC)
6. Run comprehensive test suite
7. Deploy to test environment

**Success Criteria for Phase 1:**
- All existing tests pass
- No behavior changes in authentication flows
- Performance metrics unchanged
- Zero customer impact

**Phase 2: Configuration and Observability**

1. Add provider configuration to setup files
2. Implement provider enable/disable functionality
3. Add per-provider metrics and logging
4. Update documentation
5. Gradual rollout to production

**Phase 3: Extensibility (Future)**

1. Cloud providers can add authentication mechanisms
2. Organizations can implement custom providers
3. Community contributions for additional methods

**Rollback Strategy:**

- Feature flag to switch between old and new implementation
- Comprehensive monitoring during rollout
- Automated rollback on error rate increase
- Keep original implementation available for quick revert

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

### Implementation PRs

- [ ] PR #XXX: Create AuthProvider trait and AuthProviderRegistry
- [ ] PR #XXX: Refactor SCRAM authentication into ScramProvider
- [ ] PR #XXX: Refactor OIDC authentication into OidcProvider
- [ ] PR #XXX: Update auth handler to use registry
- [ ] PR #XXX: Add provider configuration support
- [ ] PR #XXX: Add comprehensive test suite
- [ ] PR #XXX: Update documentation

### Status Updates

*Status updates will be added as implementation progresses*

### Open Questions

*Open questions will be tracked here as they arise during implementation*

### Implementation Notes

*Implementation notes will be captured as work progresses*
