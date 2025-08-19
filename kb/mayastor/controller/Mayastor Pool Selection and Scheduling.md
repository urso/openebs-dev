# Mayastor Pool Selection and Scheduling

## Overview
The Mayastor control plane uses a sophisticated multi-stage pool selection system for replica placement, balancing capacity, performance, and fault tolerance requirements through filtering, scoring, and policy-based placement decisions.

## Core Scheduling Architecture

### Multi-Stage Selection Pipeline
**Implementation**: `controller/scheduling/volume_policy/simple.rs:39-49`
```rust
fn apply(self, to: AddVolumeReplica) -> AddVolumeReplica {
    DefaultBasePolicy::filter(to)
        .filter(PoolBaseFilters::min_free_space)      // Stage 1: Basic capacity
        .filter(PoolBaseFilters::encrypted)           // Stage 1: Encryption match
        .filter(PoolBaseFilters::cluster_size)        // Stage 1: Block compatibility
        .filter(SingleReplicaPolicy::replica_anti_affinity)  // Stage 1: Node distribution
        .filter_param(&self, SimplePolicy::min_free_space)   // Stage 2: Volume-specific
        .filter_param(&self, SimplePolicy::pool_overcommit)  // Stage 2: Overcommit protection
        .sort_ctx(SimplePolicy::sort_pools)                  // Stage 3: Score ranking
}
```

## Pool Selection Criteria

### Overcommit Protection
**Implementation**: `controller/scheduling/volume.rs:105-108`
```rust
pub(crate) fn overcommit(&self, allowed_commit_percent: u64, pool: &PoolWrapper) -> bool {
    let max_cap_allowed = allowed_commit_percent * pool.capacity;
    (self.size + pool.commitment()) * 100 < max_cap_allowed
}
```
Prevents thin provisioning over-allocation by calculating total commitment including new volume size.

### Anti-Affinity Enforcement
**Implementation**: `controller/scheduling/volume_policy/affinity_group.rs`
- **Node Anti-Affinity**: Ensures replicas distributed across different nodes
- **Pool Anti-Affinity**: Avoids multiple replicas on same pool when possible
- **Affinity Groups**: Honors volume group placement policies

### Pool Scoring Factors
**Implementation**: `controller/scheduling/volume_policy/simple.rs`
1. **Available Free Space**: Prioritizes pools with more available capacity
2. **Commitment Ratio**: Favors pools with lower overcommit ratios
3. **Node Distribution**: Balances load across cluster nodes
4. **Performance Characteristics**: Considers pool performance metrics

## Candidate Selection Process

### Pool Candidate Generation
**Implementation**: `controller/volume/scheduling.rs:24-34`
```rust
pub(crate) async fn volume_pool_candidates(
    request: impl Into<GetSuitablePools>,
    registry: &Registry,
) -> Vec<PoolWrapper> {
    volume::AddVolumeReplica::builder_with_defaults(request.into(), registry)
        .await
        .collect()
        .into_iter()
        .map(|e| e.collect())
        .collect()
}
```

### Replica Creation Flow
**Implementation**: `controller/volume/specs.rs:create_volume_replicas`
```rust
pub(crate) async fn create_volume_replicas(
    registry: &Registry,
    request: &CreateVolume,
    volume: &VolumeSpec,
) -> Result<CreateReplicaCandidate, SvcError> {
    // 1. Get affinity group guard for coordination
    let ag_guard = registry.specs().get_or_create_affinity_group(volume);
    
    // 2. Apply node topology constraints
    let pools = volume_pool_candidates(request, registry).await;
    
    // 3. Create candidate replicas with pool assignments
    let candidates = pools_to_replicas(pools, volume);
    
    Ok(CreateReplicaCandidate::new(candidates, ag_guard))
}
```

## Policy Implementation

### SimplePolicy Configuration
**Implementation**: `controller/scheduling/volume_policy/simple.rs:22-36`
- **No State Min Free Space**: 100% of volume size when replicas offline
- **Thin Provisioning**: Configurable overcommit limits per deployment
- **Encryption Matching**: Ensures pool encryption matches volume requirements

### Policy Application Pattern
**Implementation**: `controller/scheduling/volume_policy/mod.rs`
```rust
#[async_trait::async_trait(?Send)]
pub(crate) trait ResourcePolicy<T> {
    fn apply(self, to: T) -> T;
}
```
Pluggable policy system allows customization of placement algorithms for different deployment requirements.

## Resource Filtering Architecture

### Base Filters
**Implementation**: `controller/scheduling/volume_policy/pool.rs`
- **PoolBaseFilters::min_free_space**: Basic capacity requirements
- **PoolBaseFilters::encrypted**: Encryption compatibility checks
- **PoolBaseFilters::cluster_size**: Block size alignment validation

### Advanced Filters
**Implementation**: `controller/scheduling/volume_policy/simple.rs`
- **SimplePolicy::min_free_space**: Volume-size-aware capacity validation
- **SimplePolicy::pool_overcommit**: Thin provisioning protection logic

## Scheduling Context Management

### Volume Request Context
**Implementation**: `controller/scheduling/volume.rs:67-109`
```rust
pub(crate) struct GetSuitablePoolsContext {
    registry: Registry,
    spec: VolumeSpec,
    allocated_bytes: Option<u64>,
    move_repl: Option<MoveReplica>,
    snap_repl: bool,
    ag_restricted_nodes: Option<Vec<NodeId>>,
}
```
Maintains all context needed for pool selection including topology constraints and resource requirements.

## Integration Points

### Volume Operations
**Implementation**: `controller/volume/operations.rs`
- Integrates with volume creation workflow
- Coordinates with replica lifecycle management
- Handles error scenarios and rollback

### Node Topology
**Implementation**: `controller/scheduling/nexus.rs`
- Considers node capabilities and constraints
- Balances load across cluster topology
- Respects allowed/preferred node lists

## Key Design Principles

### Fault Tolerance Through Distribution
Pool selection ensures replicas spread across nodes and pools to maximize availability during failures.

### Capacity Management
Sophisticated overcommit protection prevents resource exhaustion while allowing efficient thin provisioning.

### Policy-Driven Flexibility
Pluggable policy system enables customization for different storage requirements and deployment scenarios.

### Performance Optimization
Scoring algorithms balance capacity, performance, and topology considerations for optimal placement.

## Related Documentation
- **[[Mayastor Control Plane Architecture]]**: Overall control plane structure
- **[[Mayastor Volume Lifecycle Management]]**: Integration with volume operations
- **[[Mayastor IO Engine - Nexus Architecture]]**: How selected pools become nexus children