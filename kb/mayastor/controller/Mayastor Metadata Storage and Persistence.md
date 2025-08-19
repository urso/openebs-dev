# Mayastor Metadata Storage and Persistence

## Overview
Mayastor uses etcd as its persistent store for all resource specifications, providing consistent metadata storage with watching, reconciliation, and transaction capabilities across the distributed control plane.

## Persistent Store Architecture

### etcd Integration
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/registry.rs:56`
```rust
pub(crate) struct Registry {
    inner: Arc<RegistryInner<Etcd>>,  // etcd-backed storage
}
```
Control plane uses etcd as the authoritative source of truth for all resource metadata with leased connections and automatic reconnection.

### Store API Abstraction
**Implementation**: `utils/pstor/src/api.rs:8-11`
```rust
#[async_trait]
pub trait Store: StoreKv + StoreObj + Sync + Send + Clone {
    async fn online(&mut self) -> bool;
}
```
Unified store interface allows for different backend implementations while maintaining consistent API semantics.

## Resource Specifications

### Core Resource Types
**Implementation**: `stor-port/types/v0/store/`

#### VolumeSpec
- Volume size, replica count, thin provisioning flags
- Topology constraints and allowed nodes
- Encryption requirements and policies
- Content source (snapshot, clone) information

#### ReplicaSpec
- Pool assignment and node location
- Size allocation and usage tracking
- Ownership relationships with volumes
- State tracking (creating, online, degraded)

#### NexusSpec  
- Child replica URIs and relationships
- NVMe-oF target configuration
- Size and protocol specifications
- Rebuild and fault tolerance state

#### PoolSpec
- Physical disk assignments and capacity
- Encryption configuration and status
- Node location and accessibility
- Usage statistics and commitment tracking

### Storage Key Structure
**Implementation**: `utils/pstor/src/products/v2.rs`
```
/mayastor/v2/
├── volumes/{volume-uuid}          # VolumeSpec
├── replicas/{replica-uuid}        # ReplicaSpec  
├── nexuses/{nexus-uuid}          # NexusSpec
├── pools/{pool-uuid}             # PoolSpec
├── nodes/{node-uuid}             # NodeSpec
├── snapshots/{snapshot-uuid}     # VolumeSnapshotSpec
└── affinity_groups/{ag-uuid}     # AffinityGroupSpec
```

## Reconciliation System

### Dirty State Detection
**Implementation**: `controller/reconciler/persistent_store.rs:18-36`
```rust
impl TaskPoller for PersistentStoreReconciler {
    async fn poll(&mut self, context: &PollContext) -> PollResult {
        if context.registry().store_online().await {
            let dirty_pools = specs.reconcile_dirty_pools(registry).await;
            let dirty_replicas = specs.reconcile_dirty_replicas(registry).await;
            let dirty_nexuses = specs.reconcile_dirty_nexuses(registry).await;
            let dirty_volumes = specs.reconcile_dirty_volumes(registry).await;
            // Sync dirty specs to etcd
        }
    }
}
```
Continuous reconciliation ensures in-memory state matches persistent store, handling partial failures and consistency issues.

### Store Operations Pattern
**Implementation**: `utils/pstor/src/api.rs:15-46`
```rust
#[async_trait]
pub trait StoreKv: Sync + Send + Clone {
    async fn put_kv<K: StoreKey, V: StoreValue>(&mut self, key: &K, value: &V) -> Result<(), Error>;
    async fn get_kv<K: StoreKey>(&mut self, key: &K) -> Result<Value, Error>;
    async fn delete_kv<K: StoreKey>(&mut self, key: &K) -> Result<(), Error>;
    async fn watch_kv<K: StoreKey>(&mut self, key: &K) -> Result<StoreWatchReceiver, Error>;
}
```

## Watch and Event System

### Resource Watching
**Implementation**: `utils/pstor/src/etcd_watcher.rs`
- **Prefix Watches**: Monitor entire resource type namespaces
- **Key Watches**: Track individual resource changes
- **Event Processing**: React to create, update, delete operations
- **Reconnection Handling**: Automatic watch re-establishment on failures

### Event Propagation
**Implementation**: `controller/resources/operations_helper.rs`
```rust
pub(crate) async fn notify_event<T>(
    registry: &Registry,
    resource: &T,
    event_action: EventAction,
) {
    // Generate events for external consumers
    // Update internal state caches
    // Trigger dependent resource updates
}
```

## State Management Patterns

### Resource Locking
**Implementation**: `controller/resources/operations.rs`
- **Operation Guards**: Prevent concurrent modifications during long operations
- **Read-Write Locks**: Allow concurrent reads with exclusive writes
- **Deadlock Prevention**: Ordered lock acquisition to avoid circular dependencies

### Consistency Guarantees
**Implementation**: `controller/resources/resource_map.rs`
- **Atomic Updates**: Multi-resource changes committed together
- **Version Control**: Optimistic concurrency control with version checking
- **Rollback Support**: Automatic cleanup on partial failures

## Pagination and Scalability

### Large Dataset Handling
**Implementation**: `controller/registry.rs:etcd_max_page_size`
```rust
pub(crate) async fn get_paginated_resources<T>(
    &self,
    key_prefix: &str,
    limit: i64,
) -> Result<Vec<T>, StoreError> {
    self.store.get_values_paged_all(key_prefix, self.etcd_max_page_size).await
}
```
Pagination support prevents memory exhaustion and timeout issues in large deployments.

### Caching Strategy
**Implementation**: `controller/pstor_cache.rs`
- **Resource Caching**: Frequently accessed resources cached in memory
- **Invalidation Logic**: Cache updates on store change notifications
- **Memory Bounds**: LRU eviction to prevent unbounded growth

## Data Persistence Patterns

### Transactional Updates
**Implementation**: `utils/pstor/src/etcd.rs`
- **Multi-Key Transactions**: Related resources updated atomically
- **Conditional Writes**: Updates only applied if preconditions met
- **Retry Logic**: Automatic retry on transient failures

### Backup and Recovery
**Implementation**: `utils/pstor/src/api.rs:29-44`
- **Full Snapshots**: Complete resource state extraction
- **Incremental Sync**: Delta updates for efficient synchronization
- **Cross-Region Replication**: etcd cluster replication for disaster recovery

## Configuration Management

### Store Configuration
**Implementation**: `controller/registry.rs:CoreRegistryConfig`
```rust
struct RegistryConfig {
    etcd_endpoint: String,
    etcd_max_page_size: i64,
    lease_ttl: Duration,
    reconcile_period: Duration,
}
```

### Connection Management
**Implementation**: `utils/pstor/src/etcd_keep_alive.rs`
- **Lease Management**: Automatic lease renewal for node registration
- **Connection Pooling**: Efficient etcd connection reuse
- **Health Monitoring**: Continuous store availability checking

## Error Handling Patterns

### Store Failure Scenarios
**Implementation**: `utils/pstor/src/error.rs`
- **Network Partitions**: Graceful degradation during connectivity issues
- **etcd Cluster Failures**: Automatic failover to healthy cluster members
- **Data Corruption**: Validation and recovery mechanisms

### Consistency Recovery
**Implementation**: `controller/reconciler/mod.rs`
- **State Reconciliation**: Compare live state with persistent store
- **Conflict Resolution**: Handle competing updates with consistent policies
- **Manual Recovery**: Administrative tools for resolving inconsistencies

## Integration Points

### Registry System
All resource specifications flow through the registry which coordinates between in-memory state and persistent storage.

### gRPC Services  
Service endpoints validate requests against stored specifications before executing data plane operations.

### External APIs
REST and CSI interfaces expose stored resource information to external clients and management tools.

## Performance Characteristics

### Read Optimization
- **Local Caching**: Frequently accessed data cached in memory
- **Batch Operations**: Multiple resource reads combined into single etcd requests
- **Watch Efficiency**: Incremental updates minimize network traffic

### Write Performance
- **Asynchronous Updates**: Non-blocking writes with eventual consistency
- **Batch Writes**: Related updates grouped for efficiency
- **Write-Behind Caching**: Immediate in-memory updates with async persistence

## Related Documentation
- **[[Mayastor Control Plane Architecture]]**: Overall architecture and registry design
- **[[Mayastor Volume Lifecycle Management]]**: How metadata flows through volume operations
- **[[Mayastor Pool Selection and Scheduling]]**: Resource specifications used in scheduling