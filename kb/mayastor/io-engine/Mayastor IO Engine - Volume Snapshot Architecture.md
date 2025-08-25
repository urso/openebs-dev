---
title: Mayastor IO Engine - Volume Snapshot Architecture
type: note
permalink: mayastor/io-engine/mayastor-io-engine-volume-snapshot-architecture
---

# Mayastor IO Engine - Volume Snapshot Architecture

## Overview

Mayastor's **snapshot system** provides point-in-time volume snapshots with efficient copy-on-write (COW) cloning capabilities. The system operates across two layers: the **I/O Engine** coordinates snapshot operations across multiple replicas, while individual replicas use **SPDK's native lvol snapshot functionality** for efficient COW implementation.

**Architecture**: Nexus orchestrates multi-replica snapshots → Individual replica snapshots → SPDK lvol COW implementation

**Related Documentation**: See [[SPDK LVS Snapshots]] for underlying COW mechanics and [[Mayastor IO Engine - Nexus Architecture]] for multi-replica coordination.

## Two-Layer Architecture

### Control Plane Layer (`control-plane/agents/src/bin/core/volume/`)
- **Volume snapshot coordination**: Manages snapshot creation across multiple nexus replicas
- **Clone volume creation**: Creates new volumes with snapshot-based replicas
- **Resource lifecycle**: Handles snapshot and clone resource management
- **Topology validation**: Ensures replica consistency for snapshot operations

### I/O Engine Layer (`io-engine/src/`)
- **Nexus snapshot coordination**: Synchronizes snapshots across all healthy replicas  
- **Replica snapshot creation**: Uses SPDK lvol snapshots for individual replicas
- **Clone operations**: Creates COW replicas from existing snapshots
- **Consistency enforcement**: Ensures atomic snapshot operations

## Snapshot Creation Process

### 1. Volume-Level Snapshot Request

**Control Plane Orchestration** (`control-plane/agents/src/bin/core/volume/snapshot_operations.rs`):
```rust
// Volume snapshot creation request
pub struct VolumeSnapshot {
    source_uuid: Uuid,           // Source volume UUID
    snapshot_uuid: Uuid,         // New snapshot UUID
    spec: VolumeSnapshotSpec,    // Snapshot specification
    replica_snapshots: Vec<ReplicaSnapshotSpec>, // Per-replica snapshot info
}
```

### 2. Nexus-Level Snapshot Coordination

**Snapshot Executor** (`io-engine/src/bdev/nexus/nexus_bdev_snapshot.rs:38-43`):
```rust
struct ReplicaSnapshotExecutor {
    nexus_name: String,
    replica_ctx: Vec<SnapshotExecutorReplicaCtx>,  // Snapshot UUID per replica
    skipped_replicas: Vec<String>,                 // Explicitly skipped replicas
}

struct SnapshotExecutorReplicaCtx {
    snapshot_uuid: String,         // Per-replica snapshot UUID
    replica_uuid: String,          // Target replica UUID
}
```

**Critical Process** (`nexus_bdev_snapshot.rs:298-335`):
1. **I/O Pause**: Nexus suspends all I/O to ensure consistency
2. **Parallel snapshot**: Each healthy replica snapshots simultaneously  
3. **Status collection**: Aggregate per-replica snapshot results
4. **I/O Resume**: Resume operations regardless of individual failures

### 3. Individual Replica Snapshots

**SPDK Lvol Snapshot Creation** (`io-engine/src/lvs/lvol_snapshot.rs:336-344`):
```rust
unsafe {
    vbdev_lvol_create_snapshot_ext(
        self.as_inner_ptr(),                    // Source lvol
        c_snapshot_name.as_ptr(),              // Snapshot name
        attr_descrs.as_mut_ptr(),              // Extended attributes
        SnapshotXattrs::COUNT as u32,          // Attribute count
        Some(cb),                              // Completion callback
        cb_arg,                                // Callback context
    )
};
```

**Snapshot Metadata** (`lvol_snapshot.rs:250-298`):
- `TxId`: Transaction ID for cross-replica consistency
- `EntityId`: Volume UUID that owns this snapshot
- `ParentId`: Source replica UUID  
- `SnapshotUuid`: Unique snapshot identifier
- `SnapshotCreateTime`: Creation timestamp
- `DiscardedSnapshot`: Deletion marker flag

## Consistency Guarantees

### Multi-Replica Consistency

**Topology Validation** (`nexus_bdev_snapshot.rs:61-70`):
```rust
// Ensure nexus topology matches snapshot request
if nexus.children().len() != replicas.len() {
    return Err(Error::FailedCreateSnapshot {
        name: nexus.bdev_name(),
        reason: format!(
            "Snapshot topology doesn't match nexus topology: nexus={}, snapshot={}", 
            nexus.children().len(), 
            replicas.len()
        )
    });
}
```

**Health Requirements** (`nexus_bdev_snapshot.rs:113-118`):
```rust
// Only healthy replicas participate in snapshots
if !replica.is_healthy() {
    return Err(Error::FailedCreateSnapshot {
        name: nexus.bdev_name(),
        reason: format!("Replica {} is not healthy", &r.replica_uuid),
    });
}
```

**Atomic I/O Suspension** (`nexus_bdev_snapshot.rs:312-332`):
```rust
// Step 1: Pause I/O subsystem for nexus
self.as_mut().pause().await.map_err(|error| {
    error!("Failed to pause I/O subsystem, nexus snapshot creation failed");
    error
})?;

// Step 2: Create snapshots on all replicas  
let res = self.as_mut().do_nexus_snapshot(snapshot, replicas).await;

// Step 3: Resume I/O regardless of snapshot result
if let Err(error) = self.as_mut().resume().await {
    error!("Failed to unpause nexus I/O subsystem");
}
```

### Failure Modes and Resilience

**Partial Success Handling**:
- **Strict mode (default)**: Any replica failure causes entire snapshot to fail
- **Selective mode**: Unhealthy replicas can be explicitly skipped via `skip: true` flag
- **Result tracking**: Both successful and failed replicas reported to control plane

**I/O Consistency**: I/O pause ensures all replicas snapshot identical state, even under concurrent write load.

## Clone Volume Creation

### 1. Snapshot-Based Volume Creation

**Clone Request Validation** (`control-plane/agents/src/bin/core/volume/clone_operations.rs:100-116`):
```rust
impl CreateVolumeExeVal for SnapshotCloneOp<'_> {
    fn pre_flight_check(&self) -> Result<(), SvcError> {
        let new_volume = self.0.params();
        let snapshot = self.1.as_ref();
        
        // Must be thin provisioned
        snafu::ensure!(new_volume.thin, errors::ClonedSnapshotVolumeThin {});
        
        // Must match snapshot size exactly
        snafu::ensure!(
            new_volume.size == snapshot.metadata().spec_size(),
            errors::ClonedSnapshotVolumeSize {}
        );
        
        // Snapshot must be fully created
        snafu::ensure!(snapshot.status().created(), errors::SnapshotNotCreated {});
    }
}
```

### 2. Replica Topology Inheritance

**Clone Replica Scheduling** (`clone_operations.rs:126-132`):
```rust
// Clone volume gets exactly the same number of replicas as snapshot
if volume.num_replicas > clonable_snapshots.len() as u8 {
    return Err(SvcError::InsufficientSnapshotsForClone {
        snapshots: clonable_snapshots.len() as u8,
        replicas: volume.num_replicas,
        id: volume.uuid_str(),
    });
}
```

**1:1 Replica Mapping** (`clone_operations.rs:199-214`):
```rust
for snapshot in snapshots {
    let clone_id = SnapshotCloneId::new();
    let clone_name = clone_id.to_string();
    let repl_params = SnapshotCloneParameters::new(
        snapshot.spec().uuid().clone(),
        clone_name, 
        clone_id
    );
    
    // Clone created on same pool as source snapshot
    let pool = pools.remove(0);
    let clone_spec_param = SnapshotCloneSpecParams::new(
        repl_params,
        snapshot.meta().source_spec_size(),
        pool.pool().pool_ref(),
        pool.pool.node.clone(),         // Same node as snapshot
        new_volume.uuid.clone(),
    );
    clone_spec_params.push(clone_spec_param);
}
```

### 3. Individual Clone Creation

**SPDK Lvol Clone** (`io-engine/src/lvs/lvol_snapshot.rs:445-453`):
```rust
unsafe {
    vbdev_lvol_create_clone_ext(
        self.as_inner_ptr(),                    // Source snapshot lvol
        c_clone_name.as_ptr(),                 // Clone name
        attr_descrs.as_mut_ptr(),              // Clone metadata
        CloneXattrs::COUNT as u32,             // Metadata count
        Some(cb),                              // Completion callback
        cb_arg,                                // Callback context
    )
};
```

**Clone Metadata** (`lvol_snapshot.rs:382-422`):
- `SourceUuid`: Source snapshot UUID for traceability
- `CloneCreateTime`: Clone creation timestamp  
- `CloneUuid`: Unique clone identifier

## Copy-on-Write (COW) Implementation

### SPDK Integration
Mayastor leverages SPDK's native COW implementation:
- **Backing device chain**: Clone → Snapshot → (optional parent chain)
- **Read delegation**: Unallocated reads automatically served from snapshot
- **Write allocation**: Modified blocks allocated in clone, original preserved in snapshot
- **Space efficiency**: Only modified data consumes additional storage

*See [[SPDK LVS Snapshots]] for detailed COW mechanics including read/write paths, chain traversal, and performance characteristics.*

### Mayastor-Specific Features

**Multi-Replica COW Coordination**:
- Each replica maintains independent COW relationship with its snapshot
- Nexus coordinates reads/writes across multiple COW-enabled children  
- Load balancing across replicas improves COW read performance
- Write amplification minimized through nexus-level batching

**Clone Health Monitoring**:
- Clone replicas participate in standard nexus fault detection
- Snapshot health impacts clone availability
- Chain depth monitoring for performance optimization

## Snapshot Management Operations

### Snapshot Listing

**Per-Replica Listing** (`io-engine/src/lvs/lvol_snapshot.rs:608-629`):
```rust
fn list_snapshot_by_source_uuid(&self) -> Vec<SnapshotDescriptor> {
    let mut snapshot_list: Vec<SnapshotDescriptor> = Vec::new();
    let mut lvol_snap_iter = LvolSnapshotIter::new(self.clone());
    let self_uuid = self.uuid();
    
    while let Some(volume_snap_descr) = lvol_snap_iter.parent() {
        // Only include snapshots from this source UUID
        if volume_snap_descr.source_uuid != self_uuid {
            break;
        }
        snapshot_list.push(volume_snap_descr);
    }
    snapshot_list
}
```

### Snapshot Deletion

**Conditional Deletion Logic** (`lvol_snapshot.rs:591-604`):
```rust
async fn destroy_snapshot(mut self) -> Result<(), Self::Error> {
    if self.list_clones_by_snapshot_uuid().is_empty() {
        // No clones exist, safe to delete immediately
        self.destroy().await?;
    } else {
        // Mark as discarded, actual deletion when last clone removed
        self.set_blob_attr(
            SnapshotXattrs::DiscardedSnapshot.name(),
            true.to_string(),
            true,
        ).await?;
    }
    Ok(())
}
```

**Garbage Collection** (`lvol_snapshot.rs:748-775`):
```rust
async fn destroy_pending_discarded_snapshot() {
    let snap_list = bdev
        .into_iter()
        .filter(|b| b.driver() == "lvol")
        .map(|b| Lvol::try_from(b).unwrap())
        .filter(|b| {
            b.is_snapshot() 
                && b.is_discarded_snapshot()
                && b.list_clones_by_snapshot_uuid().is_empty()  // No remaining clones
        })
        .collect::<Vec<Lvol>>();
        
    // Clean up orphaned discarded snapshots
    let futures = snap_list.into_iter().map(|s| s.destroy());
    join_all(futures).await;
}
```

## Performance and Optimization

### Snapshot Chain Management

**Chain Depth Impact**:
- Read latency increases with snapshot chain depth
- Each unallocated read traverses backing device chain
- Mayastor inherits SPDK's chain traversal performance characteristics

**Optimization Operations**:
- **Inflation**: Copy all backing data to break chain dependencies
- **Parent decoupling**: Remove single level of backing device dependency  
- **Chain monitoring**: Track depth for performance management

### Multi-Replica Performance Benefits

**Read Load Balancing**:
```rust
// Nexus distributes reads across healthy replicas
pub(crate) fn select_reader(&self) -> Option<&dyn BlockDeviceHandle> {
    if self.readers.is_empty() {
        None
    } else {
        let idx = (*idx + 1) % self.readers.len();  // Round-robin
        Some(self.readers[idx].as_ref())
    }
}
```

**Benefits**:
- Multiple snapshot chains serve reads in parallel
- COW read amplification distributed across replicas
- Failed replica reads automatically retry with healthy replicas

### Write Performance Characteristics

**COW Write Amplification**: 
- First write to unallocated cluster triggers full cluster COW operation
- Amplification = `cluster_size / write_size` (e.g., 4KB write → 4MB cluster = 1000x)
- Multi-replica writes suffer amplification on each replica independently

## Failure Scenarios and Recovery

### Snapshot Creation Failures

**Partial Success Scenarios**:
1. **I/O pause failure**: Snapshot aborted, no state change
2. **Individual replica failure**: Failed replicas reported, successful replicas may proceed (if `skip: true`)
3. **I/O resume failure**: Snapshot may succeed but nexus becomes non-operational

**Recovery Actions**:
- Failed snapshots leave no persistent state changes
- Successful partial snapshots can be used for subsequent clone operations
- I/O resume failures require nexus restart or reconnection

### Clone Creation Failures

**Common Failure Modes**:
1. **Insufficient snapshots**: Not enough healthy snapshot replicas for requested clone replica count
2. **Pool unavailability**: Target pools for clone placement unavailable
3. **Individual clone failure**: Some replicas succeed, others fail during clone creation

**Resilience Design**:
- Clone creation is atomic per replica (succeeds completely or fails cleanly)
- Partial clone success results in degraded but functional volume
- Failed clones can be recreated from available snapshots

### Snapshot Chain Corruption

**Detection and Recovery**:
- **Chain validation**: Periodic integrity checks of backing device relationships
- **Orphan detection**: Identify and clean up disconnected snapshot chains
- **Metadata reconstruction**: Recover from snapshot metadata corruption where possible

## Example Workflows

### Basic Snapshot and Clone Workflow

```bash
# 1. Create volume with 2 replicas
mayastor-cli volume create vol1 --size 1GiB --replicas 2

# 2. Take volume snapshot (all replicas)
mayastor-cli snapshot create vol1 snap1

# 3. Create clone volume from snapshot (inherits 2 replicas)
mayastor-cli volume create-from-snapshot snap1 clone-vol1 --size 1GiB
```

**Result**: 
- `snap1` contains snapshots of both `vol1` replicas
- `clone-vol1` has 2 COW replicas, one from each `snap1` replica
- `clone-vol1` placed on same nodes/pools as original replicas

### Degraded Snapshot Scenario

```rust
// Request with explicit replica skipping
NexusReplicaSnapshotDescriptor {
    replica_uuid: "healthy-replica-uuid",
    snapshot_uuid: Some("snap-uuid-1"),
    skip: false,
},
NexusReplicaSnapshotDescriptor {
    replica_uuid: "faulted-replica-uuid", 
    snapshot_uuid: None,
    skip: true,    // Explicitly skip unhealthy replica
},
```

**Result**: Single-replica snapshot created, clone volumes will have single replica.

## Source Code Locations

### I/O Engine Implementation
- **Nexus snapshot coordination**: `io-engine/src/bdev/nexus/nexus_bdev_snapshot.rs`
- **Lvol snapshot operations**: `io-engine/src/lvs/lvol_snapshot.rs`
- **Snapshot gRPC service**: `io-engine/src/grpc/v1/snapshot.rs`
- **Snapshot tests**: `io-engine/tests/snapshot_nexus.rs`, `io-engine/tests/snapshot_lvol.rs`

### Control Plane Implementation  
- **Volume snapshot operations**: `control-plane/agents/src/bin/core/volume/snapshot_operations.rs`
- **Clone volume creation**: `control-plane/agents/src/bin/core/volume/clone_operations.rs`
- **Snapshot scheduling**: `control-plane/agents/src/bin/core/controller/scheduling/volume.rs`

### Protocol Definitions
- **Snapshot gRPC API**: `io-engine/protobuf/v1/snapshot.proto`
- **Control plane types**: `control-plane/stor-port/src/types/v0/store/snapshots/`

## Limitations and Considerations

### Current Limitations
1. **Thin provisioning requirement**: Clone volumes must be thin-provisioned
2. **Size matching**: Clone volumes must match source snapshot size exactly
3. **Same-pool placement**: Clone replicas created on same pools as snapshot replicas
4. **No cross-nexus snapshots**: Snapshots limited to single nexus/volume
5. **Manual optimization**: No automatic snapshot chain depth management

### Performance Considerations
1. **COW amplification**: First writes to cloned data incur significant amplification
2. **Chain depth impact**: Long snapshot chains degrade read performance
3. **Multi-replica overhead**: Each replica independently manages COW operations
4. **I/O suspension**: Snapshot creation briefly pauses all volume I/O

### Operational Considerations
1. **Capacity planning**: Account for COW space requirements in pool sizing
2. **Performance monitoring**: Track snapshot chain depths and COW ratios
3. **Garbage collection**: Regular cleanup of discarded snapshots
4. **Backup integration**: Coordinate snapshots with external backup systems