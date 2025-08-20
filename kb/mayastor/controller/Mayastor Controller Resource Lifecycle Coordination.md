---
title: Mayastor Controller Resource Lifecycle Coordination
type: note
permalink: mayastor/controller/mayastor-controller-resource-lifecycle-coordination
---

# Mayastor Controller Resource Lifecycle Coordination  

## Overview
Mayastor Controller coordinates complex resource lifecycles across distributed components, handling dependencies, cascading operations, and failure scenarios during volume management operations.

## Lifecycle Coordination Patterns

### Volume Switchover Orchestration
**Implementation**: `controller/control-plane/stor-port/src/types/v0/store/switchover.rs:15-28`
```rust
pub enum Operation {
    Init,               // Initialize switchover request
    RepublishVolume,    // Shutdown old target, create new nexus
    ReplacePath,        // Send updated path to node-agent  
    DeleteTarget,       // Delete original target
    Successful,         // Mark switchover complete
    Errored(String),    // Failed switchover
}
```
State machine coordinates multi-step operations across control plane and data plane.

### HA Cluster Coordination
**Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs:287-308`
```rust
async fn republish_volume(&mut self, etcd: &EtcdStore) -> Result<(), anyhow::Error> {
    let vol = match self.send_republish_volume(false).await {
        Ok(vol) => vol,
        Err(e) if e.kind == ResourceMissing => {
            // Nexus missing, try creating new one
            self.send_republish_volume(true).await
        }
        Err(e) => return Err(e),
    };
}
```
Graceful handling of missing resources during coordination operations.

## Cross-Component Dependencies

### Node Failure Detection and Response
**Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/nodes.rs:14-31`
```rust
struct PathRecord {
    _socket: SocketAddr,
    stage: SwitchOverStage,     // Track switchover progress
}

pub(crate) struct NodeList {
    list: Arc<Mutex<HashMap<NodeId, SocketAddr>>>,           // Active nodes
    failed_path: Arc<Mutex<HashMap<String, PathRecord>>>,   // Failed connections
}
```
HA cluster agent tracks node health and failed paths for coordinated recovery.

### Nexus to IO-Engine Coordination
**Implementation**: `io-engine/io-engine/src/bdev/nexus/nexus_persistence.rs:321`
```rust
if info.key_info.inner_mut().do_self_shutdown {
    self.try_self_shutdown();  // IO-engine checks flag and shuts down
}
```
Coordination flags enable safe nexus transitions during switchover operations.

### Volume Publishing Coordination  
**Implementation**: `controller/control-plane/agents/src/bin/core/volume/operations.rs:612-640`
```rust
let result = match nexus.share(registry, &ShareNexus::new(&nexus_state, request.share, allowed_host)).await {
    Ok(_) => Ok(()),
    Err(error) => {
        // Rollback on failure: destroy nexus and clean up
        nexus.destroy(registry, &DestroyNexus::from(nexus_state).with_disown_all()).await.ok();
        Err(error)
    }
};
```
Atomic operations with automatic rollback on partial failures.

## Resource Dependency Management

### Pool to Replica Dependencies
**Implementation**: `controller/control-plane/agents/src/bin/core/volume/specs.rs:23-47`
```rust
pub(crate) async fn create_volume_replicas(
    registry: &Registry,
    request: &CreateVolume,
) -> Result<Vec<CreateReplicaCandidate>, SvcError> {
    // Ensure pools exist before creating replicas
    let candidates = volume_policy.candidates(registry, request, CreateVolumeType::Volume).await?;
}
```
Pool availability verified before replica placement decisions.

### Replica to Nexus Dependencies
**Implementation**: `controller/control-plane/agents/src/bin/core/volume/operations.rs:585-590`
```rust
// Create a Nexus on the requested or auto-selected node
let result = self.create_nexus(registry, &target_cfg).await;
let (mut nexus, nexus_state) = self.validate_update_step(registry, result, &spec_clone).await?;
```
Replicas must be available before nexus creation can proceed.

### Cascading Deletion Coordination
**Implementation**: `controller/k8s/operators/src/pool/context.rs:164-178`
```rust
pub(crate) async fn delete_finalizer(resource: ResourceContext, attempt_delete: bool) -> Result<Action, Error> {
    if attempt_delete {
        resource.delete_pool().await?;     // Delete from control plane first
    }
    if ctx.remove(resource.name_any()).await.is_none() {
        return Ok(Action::requeue(Duration::from_secs(10)));  // Retry on failure
    }
}
```
Finalizers ensure proper cleanup order and retry failed deletions.

## Operation Sequencing

### Volume Creation Sequence
**Implementation**: `controller/control-plane/agents/src/bin/core/volume/operations.rs`
1. **Validate Request**: Check size, replica count, policy constraints
2. **Schedule Replicas**: Select pools and nodes based on topology
3. **Create Replicas**: Provision storage on selected pools
4. **Create Nexus**: Build volume target from available replicas
5. **Share Nexus**: Expose volume via NVMe-oF protocol
6. **Update Status**: Mark volume as created and available

### Volume Switchover Sequence  
**Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs:546`
```rust
match request.stage.read() {
    Stage::Init => request.init().await,
    Stage::RepublishVolume => request.republish_volume(&self.etcd).await,
    Stage::ReplacePath => request.replace_path().await,  
    Stage::DeleteTarget => request.delete_target().await,
}
```
Multi-stage coordination ensures safe volume migration between nodes.

### Cleanup Coordination
**Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs:448-464`
```rust
async fn delete_target(&mut self) -> Result<(), anyhow::Error> {
    self.destroy_all_shutdown_targets().await?;  // Clean up old targets
    nodes.remove_failed_path(&self.existing_nqn).await;  // Clear failed paths
}
```
Coordinated cleanup prevents resource leaks during operation failures.

## Failure Recovery Coordination

### Partial Failure Handling
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/resources/operations_helper.rs`
```rust
async fn validate_update_step<T>(&self, registry: &Registry, result: Result<T, SvcError>) -> Result<T, SvcError> {
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            // Rollback partial changes and clean up inconsistent state
            self.complete_update(registry, Err(error.clone()), spec_clone).await?;
            Err(error)
        }
    }
}
```
Automatic rollback coordination when operations fail partially.

### State Reconciliation Coordination
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/reconciler/mod.rs:75`
- **Detect Inconsistencies**: Compare desired vs actual state across components
- **Coordinate Repairs**: Sequence repair operations to maintain dependencies  
- **Monitor Progress**: Track reconciliation completion across resource types

### Cross-Component Recovery
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/reconciler/volume/nexus.rs`
- **Nexus Recreation**: Rebuild missing nexuses from available replicas
- **Target Republishing**: Restore volume targets after node failures
- **Path Recovery**: Update initiator paths after nexus migration

## Event Coordination

### Resource State Events
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/resources/operations_helper.rs`
```rust
pub(crate) async fn notify_event<T>(registry: &Registry, resource: &T, event_action: EventAction) {
    // Notify dependent resources of state changes
    // Trigger cascading updates where needed
    // Generate external events for monitoring
}
```
Event propagation coordinates dependent resource updates.

### Health Status Coordination
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/resources/migration.rs`
- **Health Monitoring**: Track resource health across all components
- **Degradation Detection**: Identify when resources enter degraded states
- **Recovery Triggering**: Coordinate recovery operations for unhealthy resources

## Related Documentation
- **[[Mayastor Controller State Resilience and Recovery]]**: Overall coordination during failures
- **[[Mayastor Volume Lifecycle Management]]**: End-to-end volume operation coordination