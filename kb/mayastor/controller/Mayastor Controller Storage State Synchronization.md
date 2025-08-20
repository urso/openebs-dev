---
title: Mayastor Controller Storage State Synchronization
type: note
permalink: mayastor/controller/mayastor-controller-storage-state-synchronization
---

# Mayastor Controller Storage State Synchronization

## Overview
Mayastor Controller maintains state consistency across multiple storage backends: control plane etcd, Kubernetes API, and io-engine instances through active synchronization mechanisms.

## State Architecture

### Data Flow Hierarchy
```
User Creates CRD → K8s Operator → Control Plane REST API → Control Plane etcd
                ↑                                                    ↓
            Reconciliation ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ←
```
Control plane etcd serves as authoritative source; K8s resources are user-facing interfaces.

### Control Plane etcd (Source of Truth)
**Implementation**: `controller/control-plane/stor-port/src/types/v0/store/`
```rust
pub struct VolumeSpec {
    pub uuid: VolumeId,
    pub size: u64,
    pub num_replicas: u8,
    pub status: VolumeSpecStatus,  // Creating, Created, Deleting, Deleted
    pub target_config: Option<TargetConfig>,
    // ... complete resource specifications
}
```
Stores complete resource specifications, lifecycle states, and coordination metadata.

### Kubernetes Resources (User Interface)
**Implementation**: `controller/k8s/operators/src/pool/diskpool/crd/`
- **Standard PVCs/PVs**: Volume storage via CSI driver
- **Custom CRDs**: Infrastructure resources (DiskPools, etc.)
- **Created FROM control plane state**, not source of specifications

### IO-Engine Local State (Coordination Only)
**Implementation**: `io-engine/io-engine/src/bdev/nexus/nexus_persistence.rs:40-47`
```rust
pub struct NexusInfo {
    pub clean_shutdown: bool,     // Safe restart coordination
    pub do_self_shutdown: bool,   // Switchover coordination flag
    pub children: Vec<ChildInfo>, // Child health tracking
}
```
Minimal coordination state for safe operations; no complete resource reconstruction.

## Synchronization Mechanisms

### CRD to Control Plane Sync
**Implementation**: `controller/k8s/operators/src/pool/context.rs:262-278`
```rust
pub(crate) async fn create_or_import(self) -> Result<Action, Error> {
    // CRD change triggers control plane API call
    let response = self.pools_api().create_pool(&create_request).await;
}
```
K8s operators translate CRD operations into control plane REST API calls.

### Control Plane to CRD Sync  
**Implementation**: `controller/k8s/operators/src/pool/diskpool/client.rs:83-113`
```rust
if let Ok(pools) = control_client.pools_api().get_pools(None).await {
    // Create missing CRDs for pools that exist in control plane
    for pool in pools.into_body().iter_mut() {
        match pools_api.get(&pool.id).await {
            Err(kube::Error::Api(e)) if e.code == StatusCode::NOT_FOUND => {
                let new_disk_pool: DiskPool = DiskPool::new(&pool.id, cr_spec);
                pools_api.create(&param, &new_disk_pool).await?;
            }
        }
    }
}
```
Operators query control plane and create missing CRDs on startup/reconciliation.

### Volume Lifecycle Sync
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:105-126`
```rust
async fn delete_orphan_volumes(&self) {
    let volumes = self.collect_volume_ids().await;        // From control plane
    let pvcs = self.collect_pvc_ids().await;             // From Kubernetes
    
    for volume_uid in volumes {
        if self.is_vol_orphan(volume_uid, &pvcs).await { // No corresponding PVC
            self.delete_volume(volume_uid).await;         // Clean up from control plane
        }
    }
}
```
CSI controller synchronizes volume state between Kubernetes PVCs and control plane storage.

## State Conflict Resolution

### CRD vs Control Plane Conflicts
**Implementation**: `controller/k8s/operators/src/pool/context.rs:455-467`
```rust
if response.status() == StatusCode::NOT_FOUND {
    if self.metadata.deletion_timestamp.is_some() {
        // Normal deletion - stop processing
    } else {
        // External deletion detected - warn but don't recreate
        tracing::warn!(pool = ?self.name_any(), "deleted by external event NOT recreating");
        self.mark_pool_not_found().await;
    }
}
```
System respects deliberate CRD deletions and doesn't automatically recreate them.

### Orphan Detection and Cleanup  
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:120-125`
```rust
tokio::time::sleep(std::time::Duration::from_secs(60)).await;  // Grace period
for volume_uid in gc_uids {
    if self.is_vol_orphan(volume_uid, &pvcs).await {         // Double-check
        self.delete_volume(volume_uid).await;
    }
}
```
60-second grace period and double-checking prevent race conditions during conflict resolution.

### Multi-Agent HA Coordination
**HA Cluster Agent**: `controller/control-plane/agents/src/bin/ha/cluster/main.rs`
```rust
// Receives switchover requests, coordinates across nodes
let switchover_request = SwitchoverRequest {
    volume_uuid: failed_volume,
    target_node: selected_node,
    requester: node_agent_id,
};
// Store in etcd for crash-resistant processing
etcd_client.put(switchover_key, serialize(&switchover_request)).await?;
```

**Node Agent Coordination**: `controller/control-plane/agents/src/bin/ha/node/main.rs`  
```rust
// Reports path failures to HA cluster agent
let failure_report = PathFailureReport {
    client_node: self.node_id,
    volume_uuid: failed_volume,
    nexus_endpoint: failed_endpoint,
    failure_type: PathFailureType::NvmeConnecting,
};
// Triggers distributed switchover process
```

**etcd CAS Operations**: All multi-agent coordination uses Compare-and-Swap for atomic distributed updates.

## Consistency Guarantees

### Eventual Consistency Model
- **Control plane etcd**: Immediate consistency for all operations
- **Kubernetes CRDs**: Eventually consistent with control plane via reconciliation
- **IO-engine state**: Eventually consistent via reconciliation loops

### Reconciliation Loops
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/reconciler/mod.rs`
- Continuous comparison between desired state (etcd) and actual state (io-engines)
- Automatic correction of detected inconsistencies
- Configurable reconciliation periods for different resource types

## Error Handling Patterns

### State Synchronization Failures
**Implementation**: `controller/k8s/operators/src/pool/context.rs:234-239`
```rust
async fn mark_pool_not_found(&self) -> Result<Action, Error> {
    self.patch_status(DiskPoolStatus::not_found(&self.inner.status)).await?;
    error!(name = ?self.name_any(), "Pool not found, clearing status");
    Ok(Action::requeue(Duration::from_secs(30)))  // Retry synchronization
}
```
Failed synchronization operations are retried with exponential backoff.

### Split-Brain Prevention
**Implementation**: `controller/control-plane/stor-port/src/types/v0/store/registry.rs`
- Single control plane instance holds etcd lease
- Operator leadership election prevents multiple active instances
- Atomic operations ensure consistent multi-resource updates

## Related Documentation
- **[[Mayastor Metadata Storage and Persistence]]**: etcd storage architecture
- **[[Mayastor Controller Component Restart Behavior]]**: How sync works during restarts