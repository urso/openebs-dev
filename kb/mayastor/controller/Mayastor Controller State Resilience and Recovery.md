---
title: Mayastor Controller State Resilience and Recovery
type: note
permalink: mayastor/controller/mayastor-controller-state-resilience-and-recovery
---

# Mayastor Controller State Resilience and Recovery

## Overview
The Mayastor Controller implements multiple resilience mechanisms to handle component failures, missed events, and state inconsistencies across io-engine restarts and control plane outages.

## Resilience Architecture

### Multi-Layer Recovery System
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:101-104`
```rust
/// Deletes orphaned volumes (ie volumes with no corresponding PV) which can be useful:
/// 1. if there is any missed events at startup  
/// 2. to tackle k8s bug where volumes are leaked when PV deletion is attempted before PVC
```
Dual-mode recovery handles both real-time event processing and catch-up scenarios.

### HA Switchover Coordination
**Implementation**: `controller/control-plane/agents/src/bin/core/volume/operations.rs:595-608`
```rust
if let Some(mut old_nexus_info) = old_nexus_info {
    old_nexus_info.do_self_shutdown = true;              // Signal old nexus for shutdown
    old_nexus_info.volume_uuid = Some(spec_clone.uuid.clone());
    registry.store_obj_cas(&old_nexus_info, mod_rev).await?;  // Atomic etcd update
}
```

**HA Cluster Agent Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs`
```rust
// 5-stage switchover process with WAL persistence
async fn execute_switchover(&mut self, request: SwitchoverRequest) -> Result<(), Error> {
    // Stage 1: Init - Create persistent switchover request
    self.store_switchover_state(SwitchoverStage::Init, &request).await?;
    
    // Stage 2: RepublishVolume - Create new nexus, shutdown old
    self.republish_volume(&request.volume_uuid).await?;
    self.store_switchover_state(SwitchoverStage::RepublishVolume, &request).await?;
    
    // Stages 3-5: Path replacement, cleanup, completion
    // ... each stage persisted for crash recovery
}
```

**Write-Ahead Log Recovery**: Incomplete switchover operations are replayed on HA agent restart, ensuring exactly-once switchover guarantees.

## Component Recovery Patterns

### Control Plane Core Agent Recovery
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/registry.rs:56`
- Registry loads complete state from etcd on startup
- Reconciliation loops sync with io-engine instances
- Missing resources recreated based on stored specifications

### K8s Operator Recovery  
**Implementation**: `controller/k8s/operators/src/pool/diskpool/client.rs:78-83`
```rust
/// Reconciles control-plane pools into CRs by listing pools from the control plane
/// and creating equivalent CRs if respective CR is not present.
if let Ok(pools) = control_client.pools_api().get_pools(None).await {
```
Operators query control plane state and recreate missing CRDs on startup.

### CSI Controller Recovery
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:89-98`
```rust
async fn orphan_volumes_watcher(self) {
    let Some(period) = self.orphan_period else {
        return self.delete_orphan_volumes().await;  // One-time cleanup on startup
    };
```
Orphan detection runs on startup to clean up volumes without corresponding Kubernetes resources.

## Related Documentation
- **[[Mayastor Controller Component Restart Behavior]]**: Detailed restart sequence behaviors
- **[[Mayastor Controller Storage State Synchronization]]**: etcd vs Kubernetes state management