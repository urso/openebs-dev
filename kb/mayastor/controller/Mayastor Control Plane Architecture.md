---
title: Mayastor Control Plane Architecture
type: note
permalink: mayastor/controller/mayastor-control-plane-architecture
---

# Mayastor Control Plane Architecture

## Overview
The Mayastor Control Plane orchestrates storage resources across io-engine instances, handling volume lifecycle, pool management, and resource placement decisions. It operates as a separate process that communicates with io-engine data plane via gRPC.

## Core Components

### Registry System
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/registry.rs:54-57`
```rust
pub(crate) struct Registry {
    inner: Arc<RegistryInner<Etcd>>,  // etcd-backed storage
}
```
Central registry that tracks all io-engine nodes, pools, replicas, and volumes. Uses etcd for persistent state storage with reconciliation loops for consistency.

### Core Agent Services
**Implementation**: `controller/control-plane/agents/src/bin/core/`

- **Volume Service** (`volume/service.rs`): Volume creation, deletion, publishing
- **Pool Service** (`pool/service.rs`): Storage pool management and allocation
- **Nexus Service** (`nexus/service.rs`): Volume target coordination
- **Node Service** (`node/service.rs`): Node registration and health monitoring

### Resource Management Pattern
**Implementation**: `controller/resources/operations.rs`
```rust
#[async_trait::async_trait]
impl ResourceLifecycle for OperationGuardArc<VolumeSpec> {
    async fn create(registry: &Registry, request: &CreateVolume) -> Result<VolumeSpec, SvcError>
    async fn destroy(&mut self, registry: &Registry, request: &DestroyVolume) -> Result<(), SvcError>
}
```
Unified resource lifecycle management with operation guards, state validation, and rollback capabilities.

## Control Flow Architecture

### Node Registration
**Implementation**: `controller/node/registry.rs`
1. IO-engine instances register via gRPC `Register` messages
2. Registry creates `NodeWrapper` with resource tracking
3. Watchdog monitors node health via keep-alive messages
4. Node state transitions: `Online` → `Unknown` → `Offline`

### Resource Orchestration Pattern
```
gRPC Request → Service → Registry → Scheduling → Resource Creation → State Update → etcd
```

Each service follows this pattern for consistent resource management and state synchronization.

### Error Handling and Reconciliation
**Implementation**: `controller/reconciler/persistent_store.rs:18-36`
- **Dirty State Detection**: Identifies resources with pending etcd updates
- **Reconciliation Loops**: Continuously sync live state with persistent store
- **Failure Recovery**: Handles partial failures and inconsistent states

## Integration Points

### Data Plane Communication
**Implementation**: `controller/io_engine/v1/`
- **Pool Operations**: `create_pool()`, `destroy_pool()`, `import_pool()`
- **Replica Operations**: `create_replica()`, `destroy_replica()`, `share_replica()`
- **Nexus Operations**: `create_nexus()`, `add_child()`, `publish_nexus()`

### External APIs
- **REST API**: Exposes volume management to external clients
- **CSI Driver**: Kubernetes integration for dynamic provisioning
- **gRPC APIs**: Direct programmatic access to control plane functions

## Key Design Patterns

### Registry as Single Source of Truth
All resource state centralized in registry with etcd backing for persistence and consistency across control plane restarts.

### Asynchronous Operations with Guards
Operation guards prevent concurrent modifications while allowing parallel read access and long-running operations.

### Resource Wrappers
**Implementation**: `controller/wrapper/`
Wrapper types (`NodeWrapper`, `PoolWrapper`) provide controlled access to raw resources with additional functionality.

### State Reconciliation
Continuous reconciliation between in-memory state, etcd persistence, and actual data plane resources ensures consistency despite failures.

## Related Documentation
- **[[Mayastor Pool Selection and Scheduling]]**: Resource placement algorithms
- **[[Mayastor Metadata Storage and Persistence]]**: etcd-based state management  
- **[[Mayastor Volume Lifecycle Management]]**: End-to-end volume orchestration