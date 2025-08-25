---
title: Volume Restoration & Cloning
type: note
permalink: mayastor/csi-driver/volume-restoration-cloning
---

# Volume Restoration & Cloning

## Overview

This document details how Mayastor's CSI driver implements volume restoration from snapshots, creating new volumes that inherit data and topology from existing snapshots through efficient copy-on-write (COW) cloning. The implementation ensures clone volumes maintain the same replica topology as their source snapshots while enforcing thin provisioning for optimal storage efficiency.

**Related Documentation**: See [[Kubernetes Snapshot Integration]] for snapshot creation and [[CSI Driver Overview]] for architecture context.

## CSI Volume Creation with Snapshot Source

### VolumeContentSource Detection

**CSI Request Structure** (`controller.rs:380-420`):
```rust
let volume_content_source = if let Some(source) = &args.volume_content_source {
    match &source.r#type {
        Some(Type::Snapshot(snapshot_source)) => {
            let snapshot_uuid =
                Uuid::parse_str(&snapshot_source.snapshot_id).map_err(|_e| {
                    Status::invalid_argument(format!(
                        "Malformed snapshot UUID: {}",
                        snapshot_source.snapshot_id
                    ))
                })?;
            Some(snapshot_uuid)
        }
        Some(Type::Volume(_)) => {
            return Err(Status::invalid_argument(
                "Volume creation from volume source is not supported",
            ));
        }
        _ => {
            return Err(Status::invalid_argument(
                "Invalid source type for create volume",
            ));
        }
    }
} else {
    None
};
```

**Kubernetes PVC with Snapshot DataSource**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  dataSource:
    name: my-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  storageClassName: mayastor-nvmf
```

**CSI CreateVolumeRequest Translation**:
- `dataSource.name` → CSI `volume_content_source.snapshot.snapshot_id`
- External snapshotter resolves VolumeSnapshot name to snapshot UUID
- CSI receives resolved UUID, not the Kubernetes object name

### Snapshot-Based Volume Creation Logic

**Creation Path Selection** (`controller.rs:440-480`):
```rust
let volume = match volume_content_source {
    Some(snapshot_uuid) => {
        // This is to determine if user has passed `thin` arg.
        // This will help us not restore into thin volume if user has passed
        // thin:false explicitly.
        let thin_arg_passed = args.parameters.contains_key("thin");
        let thin = !thin_arg_passed || thin;
        
        RestApiClient::get_client()
            .create_snapshot_volume(
                &parsed_vol_uuid,
                &snapshot_uuid,
                replica_count,
                size,
                volume_topology,
                thin,
                affinity_group_name.map(AffinityGroup::new),
                max_snapshots,
                encrypted,
            )
            .await
            .map_err(|error| match error {
                ApiClientError::ResourceExhausted(reason) => {
                    Status::resource_exhausted(reason)
                }
                ApiClientError::PreconditionFailed(reason) => {
                    Status::resource_exhausted(reason)
                }
                error => error.into(),
            })?
    }
    None => {
        // Regular volume creation path
        RestApiClient::get_client()
            .create_volume(
                &parsed_vol_uuid,
                replica_count,
                size,
                volume_topology,
                thin,
                affinity_group_name.map(AffinityGroup::new),
                max_snapshots,
                encrypted,
                pool_cluster_size,
            )
            .await
            .map_err(|error| match error {
                ApiClientError::ResourceExhausted(reason) => {
                    Status::resource_exhausted(reason)
                }
                ApiClientError::PreconditionFailed(reason) => {
                    Status::resource_exhausted(reason)
                }
                error => error.into(),
            })?
    }
};
```

**Key Differences from Regular Volume Creation**:
1. **Different API endpoint**: `create_snapshot_volume()` vs `create_volume()`
2. **Thin provisioning enforcement**: Defaults to thin unless explicitly overridden
3. **No cluster size parameter**: Clone volumes inherit cluster configuration from snapshot
4. **Topology inheritance**: Clone placement constrained by snapshot replica locations

## REST API Client Implementation

### Snapshot Volume Creation

**Client Implementation** (`client.rs:298-331`):
```rust
/// Create a volume from a snapshot source of target size and provision storage resources for
/// it. This operation is not idempotent, so the caller is responsible for taking
/// all actions with regards to idempotency.
#[allow(clippy::too_many_arguments)]
#[instrument(fields(volume.uuid = %volume_id, snapshot.uuid = %snapshot_id), skip(self, volume_id, snapshot_id))]
pub(crate) async fn create_snapshot_volume(
    &self,
    volume_id: &uuid::Uuid,
    snapshot_id: &uuid::Uuid,
    replicas: u8,
    size: u64,
    volume_topology: CreateVolumeTopology,
    thin: bool,
    affinity_group: Option<AffinityGroup>,
    max_snapshots: Option<u32>,
    encrypted: bool,
) -> Result<Volume, ApiClientError> {
    let topology =
        Topology::new_all(volume_topology.node_topology, volume_topology.pool_topology);

    let req = CreateVolumeBody {
        replicas,
        size,
        thin,
        topology: Some(topology),
        policy: VolumePolicy::new_all(true),
        labels: None,
        affinity_group,
        max_snapshots,
        encrypted,
        cluster_size: None,  // Not supported for snapshot volumes
    };
    let result = self
        .rest_client
        .volumes_api()
        .put_snapshot_volume(snapshot_id, volume_id, req)
        .await?;
    Ok(result.into_body())
}
```

**REST API Endpoint**: 
- **URL**: `PUT /volumes/snapshots/{snapshot_id}/volumes/{volume_id}`
- **Handler**: Control plane `control-plane/agents/src/bin/core/volume/clone_operations.rs`
- **Operation**: Creates new volume using snapshot as source data

### Parameter Validation

**Thin Provisioning Logic** (`controller.rs:445-447`):
```rust
// Force thin provisioning unless explicitly disabled
let thin_arg_passed = args.parameters.contains_key("thin");
let thin = !thin_arg_passed || thin;
```

**Validation Rules**:
- **Thin enforcement**: Clone volumes default to thin provisioning for COW efficiency
- **Size matching**: Clone size must exactly match snapshot size (validated by control plane)
- **Replica constraints**: Clone replica count limited by available snapshot replicas

## Control Plane Clone Processing

### Clone Operations Implementation

**Control Plane Entry Point** (`control-plane/agents/src/bin/core/volume/clone_operations.rs:100-130`):
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
        
        Ok(())
    }
}
```

**Clone Replica Validation** (`clone_operations.rs:126-132`):
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

### Replica Topology Inheritance

**Clone Scheduling Logic** (`clone_operations.rs:180-215`):
```rust
// Create clone replicas on same pools as snapshot replicas
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

**Topology Inheritance Rules**:
1. **1:1 replica mapping**: Each clone replica created from corresponding snapshot replica
2. **Same pool placement**: Clone replicas placed on identical pools as snapshot replicas
3. **Same node placement**: Clone replicas inherit node placement from snapshot replicas
4. **Pool availability validation**: Ensures target pools have sufficient space

### Clone Creation Execution

**Parallel Clone Creation** (`clone_operations.rs:220-250`):
```rust
// Create all clone replicas in parallel
let clone_specs = future::join_all(
    clone_spec_params
        .into_iter()
        .map(|spec_param| async move {
            let pool_ref = spec_param.pool().clone();
            let result = registry
                .pool_wrapper(&pool_ref)
                .await?
                .create_snapshot_clone(&spec_param)
                .await;
            match result {
                Ok(replica) => Ok((pool_ref, replica)),
                Err(error) => {
                    error!(
                        error=%error,
                        pool.id=%pool_ref.pool_name(),
                        "Failed to create clone replica"
                    );
                    Err(error)
                }
            }
        })
).await;
```

**Error Handling**: If any clone replica fails, entire volume creation fails with detailed error reporting.

## I/O Engine Clone Implementation

### SPDK Lvol Clone Creation

**Clone Creation Function** (`io-engine/src/lvs/lvol_snapshot.rs:425-460`):
```rust
pub async fn create_clone_snapshot(
    &self,
    clone_name: String,
    clone_uuid: String,
) -> Result<Lvol, Error> {
    let c_clone_name = CString::new(clone_name.clone())?;
    let clone_uuid_copy = clone_uuid.clone();
    
    // Extended attributes for clone metadata
    let mut attr_descrs = vec![
        SnapshotDescriptor::new(
            CloneXattrs::SourceUuid.name(),
            self.uuid(),
        ),
        SnapshotDescriptor::new(
            CloneXattrs::CloneCreateTime.name(),
            Utc::now().to_rfc3339(),
        ),
        SnapshotDescriptor::new(
            CloneXattrs::CloneUuid.name(),
            clone_uuid,
        ),
    ];

    let (sender, receiver) = oneshot::channel::<ErrnoResult<()>>();
    let sender_ptr = Box::into_raw(Box::new(sender));

    unsafe {
        vbdev_lvol_create_clone_ext(
            self.as_inner_ptr(),                    // Source snapshot lvol
            c_clone_name.as_ptr(),                 // Clone name
            attr_descrs.as_mut_ptr(),              // Clone metadata
            CloneXattrs::COUNT as u32,             // Metadata count
            Some(cb),                              // Completion callback
            sender_ptr as *mut c_void,             // Callback context
        )
    };

    receiver.await.context(Cancelled)??;
    
    // Return the newly created clone lvol
    Lvol::try_from(Bdev::lookup_by_name(&clone_name)?)?
        .ok_or_else(|| Error::BdevNotFound { name: clone_name })
}
```

**SPDK Clone Semantics**:
- **Copy-on-write**: Clone shares unmodified blocks with snapshot
- **Thin provisioning**: Only modified blocks consume additional space
- **Backing device chain**: Clone → Snapshot → (optional parent chain)
- **Independent lifecycle**: Clone can outlive source snapshot

### Clone Metadata Management

**Clone Extended Attributes** (`lvol_snapshot.rs:382-422`):
```rust
pub enum CloneXattrs {
    SourceUuid,         // UUID of source snapshot
    CloneCreateTime,    // Clone creation timestamp
    CloneUuid,         // Unique clone identifier
}

impl CloneXattrs {
    pub const COUNT: usize = 3;
    
    pub fn name(&self) -> &'static str {
        match self {
            Self::SourceUuid => "source-uuid",
            Self::CloneCreateTime => "clone-create-time", 
            Self::CloneUuid => "clone-uuid",
        }
    }
}
```

**Metadata Usage**:
- **Traceability**: Links clone back to source snapshot for debugging
- **Lifecycle management**: Tracks clone creation time for garbage collection
- **Dependency tracking**: Enables detection of snapshot usage by clones

## Copy-on-Write Mechanics

### SPDK COW Implementation

**Read Path** (inherited from SPDK lvol implementation):
```rust
// Read logic (conceptual, implemented in SPDK C code)
fn read_block(clone_lvol: &Lvol, lba: u64) -> ReadResult {
    if clone_lvol.is_allocated(lba) {
        // Block modified in clone, read from clone
        clone_lvol.read_direct(lba)
    } else {
        // Block not modified, read from backing snapshot
        clone_lvol.backing_device.read(lba)
    }
}
```

**Write Path** (conceptual SPDK behavior):
```rust
// Write logic (conceptual, implemented in SPDK C code)
fn write_block(clone_lvol: &Lvol, lba: u64, data: &[u8]) -> WriteResult {
    if !clone_lvol.is_allocated(lba) {
        // First write to this block, allocate cluster
        clone_lvol.allocate_cluster_for_lba(lba)?;
        if clone_lvol.backing_device.is_allocated(lba) {
            // Copy original data from snapshot before overwrite
            let original_data = clone_lvol.backing_device.read_cluster(lba)?;
            clone_lvol.merge_write(lba, data, original_data)?;
        }
    }
    // Write to clone's allocated space
    clone_lvol.write_direct(lba, data)
}
```

**Performance Characteristics**:
- **Read amplification**: None for allocated blocks, potential backing device traversal for unallocated
- **Write amplification**: First write may trigger cluster-sized read+modify+write operation
- **Space efficiency**: Only modified blocks consume space in clone

### Chain Traversal Performance

**Backing Device Chain** (see [[SPDK LVS Snapshots]] for detailed implementation):
```
Clone Volume → Snapshot → (optional parent snapshots) → Base Volume
```

**Read Performance Impact**:
- **Direct reads**: ~10-50μs for blocks modified in clone
- **Backing reads**: +10-100μs per chain level for unmodified blocks
- **Chain depth limit**: Practical limit ~5-10 levels before performance degradation

## Error Handling and Recovery

### Common Clone Creation Failures

**Insufficient Snapshot Replicas** (`clone_operations.rs:126-132`):
```rust
// Error when requested replica count exceeds available snapshots
if volume.num_replicas > clonable_snapshots.len() as u8 {
    return Err(SvcError::InsufficientSnapshotsForClone {
        snapshots: clonable_snapshots.len() as u8,
        replicas: volume.num_replicas,
        id: volume.uuid_str(),
    });
}
```

**Size Mismatch Validation** (`clone_operations.rs:114-118`):
```rust
// Clone volume must match snapshot size exactly
snafu::ensure!(
    new_volume.size == snapshot.metadata().spec_size(),
    errors::ClonedSnapshotVolumeSize {}
);
```

**Thin Provisioning Enforcement** (`clone_operations.rs:111-113`):
```rust
// Clone volumes must be thin provisioned
snafu::ensure!(new_volume.thin, errors::ClonedSnapshotVolumeThin {});
```

### Pool Availability Failures

**Pool Space Validation**:
```rust
// Control plane validates pool has sufficient space for clone
// Failure modes:
// 1. Pool full - insufficient space for metadata
// 2. Pool offline - target pool unavailable  
// 3. Pool disconnected - network partition
```

**Recovery Strategies**:
1. **Retry with different pools**: Control plane can reschedule to alternative pools
2. **Partial clone creation**: Some replicas succeed, others fail (volume degraded)
3. **Cleanup on failure**: Failed clone replicas automatically cleaned up

### CSI Error Propagation

**Error Translation** (`controller.rs:465-475`):
```rust
.map_err(|error| match error {
    ApiClientError::ResourceExhausted(reason) => {
        Status::resource_exhausted(reason)         // Pool space, replica limits
    }
    ApiClientError::PreconditionFailed(reason) => {
        Status::resource_exhausted(reason)         // Size mismatch, thin requirement
    }
    ApiClientError::ResourceNotExists(reason) => {
        Status::not_found(reason)                  // Snapshot not found
    }
    error => Status::internal(error.to_string()), // Unexpected errors
})
```

**Kubernetes Error Handling**:
- **RESOURCE_EXHAUSTED**: PVC remains Pending, may retry with backoff
- **INVALID_ARGUMENT**: Permanent failure, requires user intervention
- **NOT_FOUND**: Snapshot deleted or invalid reference

## Advanced Clone Features

### Clone Lifecycle Management

**Clone Dependency Tracking**:
```rust
// Snapshots track active clones to prevent premature deletion
// Implementation in control-plane/agents/src/bin/core/volume/snapshot_operations.rs
fn can_delete_snapshot(snapshot_uuid: &Uuid) -> bool {
    let active_clones = registry.list_clones_for_snapshot(snapshot_uuid);
    active_clones.is_empty()
}
```

**Orphan Clone Detection**:
```rust
// Clones can outlive source snapshots in some scenarios
// Control plane tracks orphaned clones for cleanup
fn find_orphaned_clones() -> Vec<CloneId> {
    registry.list_clones()
        .filter(|clone| !registry.snapshot_exists(&clone.source_snapshot_id))
        .collect()
}
```

### Clone Chain Optimization

**Chain Breaking Operations** (inherited from SPDK):
- **Inflate clone**: Copy all backing data to break dependency chain
- **Decouple parent**: Remove single level of backing device dependency
- **Flatten on demand**: Application-triggered chain optimization

**Performance Monitoring**:
```rust
// Clone performance metrics (conceptual)
struct CloneMetrics {
    backing_reads: u64,      // Reads served from snapshot
    direct_reads: u64,       // Reads served from clone
    cow_writes: u64,         // First writes requiring COW
    chain_depth: u8,         // Current backing device chain depth
}
```

## Testing and Validation

### Clone Creation Tests

**BDD Test Coverage** (`tests/bdd/features/snapshot/csi/controller/test_operations.py:67-70`):
```python
@scenario("operations.feature", "Create Volume Operation with snapshot source")
def test_create_Volume_operation_with_snapshot_source():
    """Create Volume Operation with snapshot source."""
```

**Manual Testing Workflow**:
```bash
# 1. Create source volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: source-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: mayastor-nvmf
EOF

# 2. Create snapshot
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
spec:
  source:
    persistentVolumeClaimName: source-pvc
  volumeSnapshotClassName: mayastor-snapshot-class
EOF

# 3. Create clone volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: clone-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: test-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  storageClassName: mayastor-nvmf
EOF
```

### Performance Testing

**Clone Creation Latency**:
```bash
# Measure end-to-end clone creation time
time kubectl apply -f clone-pvc.yaml
kubectl wait pvc/clone-pvc --for=condition=Bound --timeout=30s
```

**COW Performance Testing**:
```bash
# Test write amplification on first write
fio --name=cow-test --filename=/dev/device --bs=4k --rw=randwrite --size=100M --time_based --runtime=60
```

## Limitations and Considerations

### Current Implementation Limits

**Size Constraints**:
- Clone volume must exactly match snapshot size
- No support for growing clone during restore
- No support for shrinking clone from snapshot

**Topology Constraints**:
- Clone replicas must use same pools as snapshot replicas
- No cross-pool or cross-node clone migration
- Limited by snapshot replica availability

**Performance Considerations**:
- COW write amplification on first writes
- Backing device chain traversal overhead
- Memory overhead for clone metadata tracking

### Future Enhancements

**Planned Improvements**:
1. **Resize on restore**: Allow larger clone volumes than source snapshot
2. **Cross-pool cloning**: Clone to different pool topology than source
3. **Incremental cloning**: Optimize for sequential clone creation
4. **Clone templates**: Pre-configured clone patterns for common use cases

This volume restoration and cloning system provides efficient, space-optimal volume creation from snapshots while maintaining the replica topology and data consistency guarantees of the underlying Mayastor storage system.