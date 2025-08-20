---
title: Mayastor Controller Component Restart Behavior
type: note
permalink: mayastor/controller/mayastor-controller-component-restart-behavior
---

# Mayastor Controller Component Restart Behavior

## Overview
Mayastor Controller components follow specific startup and recovery sequences to ensure state consistency and resource availability after restarts.

## IO-Engine Restart Handling

### Startup State Recovery
**Implementation**: `io-engine/io-engine/src/bdev/nexus/nexus_persistence.rs:37-47`
```rust
pub struct NexusInfo {
    pub clean_shutdown: bool,    // Nexus destroyed successfully
    pub do_self_shutdown: bool,  // Nexus needs to be shutdown
    pub children: Vec<ChildInfo>, // Information about children
}
```
IO-engines store minimal coordination state in etcd for safe startup behavior.

### Controller Nexus Reconstruction
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/reconciler/mod.rs:75`
- IO-engines start "empty" without recreating previous nexuses
- Controller recreates pools, nexuses, and replicas from etcd specifications
- No direct state transfer between old and new io-engine instances

### Self-Shutdown Coordination
**Implementation**: `io-engine/io-engine/src/bdev/nexus/nexus_persistence.rs:238`
```rust
self.try_self_shutdown();
```
IO-engines check etcd flags during startup and self-terminate if marked for shutdown.

## Control Plane Component Restarts

### Core Agent Initialization
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/registry.rs`
1. Connect to etcd and establish lease
2. Load all resource specifications from persistent store
3. Start reconciliation loops for each resource type
4. Initialize gRPC services and REST endpoints

### K8s Operator Startup Sequence
**Implementation**: `controller/k8s/operators/src/pool/main.rs:192`
```rust
create_missing_cr(&k8s, clients::tower::ApiClient::new(cfg.clone()), namespace).await?;
```
1. Connect to Kubernetes API server
2. Query control plane REST API for existing resources
3. Create missing CRDs for resources without Kubernetes representation
4. Start resource watchers and reconciliation controllers

### CSI Controller Initialization
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:33-44`
```rust
pub(crate) async fn run_watcher(&self) {
    tokio::spawn(self.clone().orphan_volumes_watcher());  // Background cleanup
    watcher(self.pv_handle.clone(), watcher::Config::default())  // Event watcher
```
1. Start orphan volume detection (immediate cleanup run)
2. Begin PV/PVC event watching
3. Initialize periodic cleanup if configured

## Restart Coordination Patterns

### Graceful vs Ungraceful Restarts
**Implementation**: `io-engine/io-engine/tests/persistence.rs:78`
```rust
assert!(nexus_info.clean_shutdown);  // Tracks restart type
```
- **Graceful**: `clean_shutdown = true`, normal startup
- **Ungraceful**: `clean_shutdown = false`, requires cleanup coordination

### Resource Recreation Priority
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/reconciler/persistent_store.rs`
1. Pools recreated first (foundation resources)
2. Replicas restored on available pools  
3. Nexuses built from available replicas
4. Volume targets published last

## State Validation After Restart

### Registry State Verification
**Implementation**: `controller/control-plane/agents/src/bin/core/controller/registry.rs`
- Compare etcd specifications with live io-engine state
- Mark inconsistencies for reconciliation
- Trigger resource recreation for missing components

### Orphan Resource Detection
**Implementation**: `controller/control-plane/csi-driver/src/bin/controller/pvwatcher.rs:105-126`
```rust
async fn delete_orphan_volumes(&self) {
    let volumes = self.collect_volume_ids().await;       // Control plane volumes
    let Some(pvcs) = self.collect_pvc_ids().await else { return; };  // K8s PVCs
    // Find volumes without corresponding PVCs and delete them
}
```
60-second grace period prevents race condition during startup.

## Related Documentation  
- **[[Mayastor Controller State Resilience and Recovery]]**: Overall resilience mechanisms
- **[[Mayastor Controller Storage State Synchronization]]**: State coordination between components