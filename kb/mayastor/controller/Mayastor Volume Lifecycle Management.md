# Mayastor Volume Lifecycle Management

## Overview
Mayastor volume lifecycle orchestrates the complete flow from volume creation requests through LVOL allocation, nexus setup, and resource cleanup, coordinating between control plane policies and data plane resource creation.

## Volume Creation Flow

### End-to-End Creation Process
**Implementation**: `controller/volume/operations.rs:55-61`
```rust
async fn create(registry: &Registry, request: &CreateVolume) -> Result<VolumeSpec, SvcError> {
    // 1. Create volume specification and validate requirements
    let volume_spec = VolumeSpec::from_request(request);
    
    // 2. Select pools and create replica candidates  
    let candidates = create_volume_replicas(registry, request, &volume_spec).await?;
    
    // 3. Create actual LVOLs on selected pools
    let replicas = create_replicas_from_candidates(candidates).await?;
    
    // 4. Store volume specification in etcd
    registry.store_volume_spec(volume_spec).await?;
}
```

### Pool Selection Integration  
**Implementation**: `controller/volume/specs.rs:create_volume_replicas`
```rust
pub(crate) async fn create_volume_replicas(
    registry: &Registry,
    request: &CreateVolume,
    volume: &VolumeSpec,
) -> Result<CreateReplicaCandidate, SvcError> {
    // 1. Acquire affinity group guard for coordination
    let ag_guard = registry.specs().get_or_create_affinity_group(volume);
    
    // 2. Get pool candidates from scheduling system
    let pools = scheduling::volume_pool_candidates(request, registry).await;
    
    // 3. Convert pool selections to replica creation requests
    let node_replicas = pools.iter().map(|pool| CreateReplica {
        uuid: ReplicaId::new(),
        pool_id: pool.id.clone(),
        node: pool.node.clone(),
        size: volume.size,
        thin: volume.thin,
        share: Protocol::None,
        ..Default::default()
    }).collect();
    
    Ok(CreateReplicaCandidate::new(node_replicas, ag_guard))
}
```

## LVOL Allocation Orchestration

### Replica Creation Process
**Implementation**: `controller/volume/operations.rs:CreateVolumeExe`
```rust
impl CreateVolumeExe for CreateVolume {
    async fn create(&self, context: &mut Context, candidates: CreateReplicaCandidate) -> Vec<Replica> {
        let mut replicas = Vec::with_capacity(candidates.candidates().len());
        
        for candidate in candidates.candidates() {
            if replicas.len() >= self.replicas as usize {
                break;  // Sufficient replicas created
            }
            
            // Create LVOL via gRPC to data plane
            match context.registry.create_replica_on_pool(candidate).await {
                Ok(replica) => replicas.push(replica),
                Err(error) => {
                    // Log error but continue with other candidates
                    context.volume.warn(&format!("Failed to create replica: {}", error));
                }
            }
        }
        replicas
    }
}
```

### Data Plane Integration
**Implementation**: `controller/io_engine/v1/replica.rs`
```rust
pub(crate) async fn create_replica(
    &self,
    request: CreateReplica,
) -> Result<Replica, SvcError> {
    // 1. Find target pool on specified node
    let pool = self.registry.find_pool(&request.pool_id).await?;
    
    // 2. Send gRPC create_replica to io-engine
    let replica_response = pool.node_client()
        .create_replica(tonic::Request::new(request.into()))
        .await?;
        
    // 3. Create ReplicaSpec and store in etcd
    let replica_spec = ReplicaSpec::from_grpc_response(replica_response);
    self.registry.store_replica_spec(replica_spec).await?;
}
```

## Nexus Creation and Management

### Nexus Child Assignment
**Implementation**: `controller/nexus/operations.rs`
```rust
async fn create_nexus_from_volume(
    registry: &Registry,
    volume_spec: &VolumeSpec,
    target_node: &NodeId,
) -> Result<NexusSpec, SvcError> {
    // 1. Get healthy replicas for nexus children
    let healthy_replicas = healthy_volume_replicas(volume_spec, target_node, registry).await?;
    
    // 2. Build child URIs from replica specifications
    let children: Vec<Child> = healthy_replicas.into_iter()
        .map(|replica| Child {
            uri: format!("lvol://{}/${}", replica.pool_id, replica.uuid),
            state: ChildState::Unknown,
            rebuild_progress: None,
        })
        .collect();
        
    // 3. Create nexus specification
    let nexus_spec = NexusSpec {
        uuid: volume_spec.uuid.clone(),
        size: volume_spec.size,
        children,
        node: target_node.clone(),
        status: NexusStatus::Unknown,
        share: Protocol::None,
    };
    
    Ok(nexus_spec)
}
```

### Target Node Selection
**Implementation**: `controller/nexus/scheduling.rs`
```rust
pub(crate) async fn target_node_candidates(
    volume_spec: &VolumeSpec,
    registry: &Registry,
) -> Vec<NodeWrapper> {
    GetSuitableNodes::builder_with_defaults(volume_spec, registry)
        .await
        .collect()
        .into_iter()
        .filter(|node| node.is_online() && node.has_io_engine())
        .collect()
}
```

## Resource Lifecycle Patterns

### Operation Guards and Concurrency
**Implementation**: `controller/resources/operations_helper.rs`
```rust
pub(crate) struct OperationGuardArc<T> {
    resource: Arc<RwLock<T>>,
    _guard: Arc<tokio::sync::Mutex<()>>,
}

impl<T> OperationGuardArc<T> {
    pub(crate) async fn operation_guard_wait(&self) -> Result<Self, SvcError> {
        let guard = self._guard.lock().await;
        Ok(Self { resource: self.resource.clone(), _guard: Arc::new(guard) })
    }
}
```
Operation guards prevent concurrent modifications during long-running operations like volume creation.

### Error Handling and Rollback
**Implementation**: `controller/volume/operations.rs:OnCreateFail`
```rust
pub(crate) async fn validate_create_step_ext<T>(
    &self,
    registry: &Registry, 
    result: Result<T, SvcError>,
    on_fail: OnCreateFail,
) -> Result<T, SvcError> {
    match result {
        Ok(success) => Ok(success),
        Err(error) => {
            match on_fail {
                OnCreateFail::Delete => {
                    // Cleanup partially created resources
                    self.cleanup_partial_creation(registry).await;
                }
                OnCreateFail::Leave => {
                    // Leave resources for manual cleanup
                }
            }
            Err(error)
        }
    }
}
```

## Volume Publishing and Sharing

### Volume Publishing Flow
**Implementation**: `controller/volume/operations.rs:ResourcePublishing`
```rust
impl ResourcePublishing for OperationGuardArc<VolumeSpec> {
    async fn publish(&mut self, registry: &Registry, request: &PublishVolume) -> Result<Volume, SvcError> {
        // 1. Create or find existing nexus on target node
        let nexus = self.ensure_nexus_on_node(registry, &request.target_node).await?;
        
        // 2. Share nexus with specified protocol (NVMe-oF)
        let share_uri = nexus.share_nexus(registry, request.share_protocol).await?;
        
        // 3. Update volume state to published
        self.set_operation(VolumeOperation::Publish(PublishOperation {
            target_node: request.target_node.clone(),
            share_uri,
            frontend_nodes: request.frontend_nodes.clone(),
        })).await?;
        
        Ok(self.as_volume())
    }
}
```

### Protocol Integration
**Implementation**: `controller/nexus/operations.rs`
- **NVMe-oF Sharing**: Creates NVMe-oF targets for remote access
- **Local Access**: Direct block device access for local applications  
- **Multi-Path**: Supports multiple nexus instances for high availability

## Volume Destruction and Cleanup

### Cleanup Orchestration
**Implementation**: `controller/volume/operations.rs:destroy`
```rust
async fn destroy(&mut self, registry: &Registry, request: &DestroyVolume) -> Result<(), SvcError> {
    // 1. Start volume destruction process
    self.start_destroy(registry).await?;
    
    // 2. Destroy associated nexuses
    let nexuses = registry.specs().volume_nexuses(&request.uuid);
    for nexus in nexuses {
        match nexus.destroy(registry).await {
            Ok(()) => info!("Nexus destroyed successfully"),
            Err(error) => warn!("Nexus cleanup failed: {}", error),
        }
    }
    
    // 3. Destroy volume replicas  
    let replicas = registry.specs().volume_replicas(&request.uuid);
    for replica in replicas {
        match replica.destroy(registry).await {
            Ok(()) => info!("Replica destroyed successfully"), 
            Err(error) => warn!("Replica cleanup failed: {}", error),
        }
    }
    
    // 4. Remove volume specification from etcd
    registry.remove_volume_spec(&request.uuid).await?;
}
```

### Garbage Collection
**Implementation**: `controller/reconciler/volume/garbage_collector.rs`
- **Orphaned Resources**: Cleanup resources without parent volumes
- **Failed Operations**: Remove partially created resources
- **Unreachable Nodes**: Mark resources for cleanup when nodes offline

## Snapshot and Clone Operations

### Volume Snapshot Creation
**Implementation**: `controller/volume/snapshot_operations.rs`
```rust
pub(crate) async fn create_volume_snapshot(
    registry: &Registry,
    request: &CreateVolumeSnapshotRequest,
) -> Result<VolumeSnapshot, SvcError> {
    // 1. Find source volume and validate state
    let source_volume = registry.specs().volume(&request.source_id).await?;
    
    // 2. Create snapshot on all healthy replicas
    let snapshot_replicas = create_replica_snapshots(
        registry, 
        &source_volume,
        &request.snapshot_id
    ).await?;
    
    // 3. Store snapshot specification  
    let snapshot_spec = VolumeSnapshotSpec::from_replicas(snapshot_replicas);
    registry.store_snapshot_spec(snapshot_spec).await?;
}
```

### Clone Volume Creation
**Implementation**: `controller/volume/clone_operations.rs`
- **Snapshot Source**: Create volume from existing snapshot
- **Cross-Pool Clones**: Support cloning across different storage pools
- **Incremental Clones**: Efficient copy-on-write clone operations

## Integration Points

### CSI Driver Integration
**Implementation**: `control-plane/csi-driver/src/node.rs`
- **Volume Staging**: Prepare volumes for pod attachment
- **Volume Publishing**: Mount volumes into pod filesystems
- **Capacity Management**: Report available storage capacity

### REST API Integration  
**Implementation**: `control-plane/rest/src/volumes.rs`
- **CRUD Operations**: Create, read, update, delete volumes
- **Status Monitoring**: Real-time volume health and performance
- **Batch Operations**: Efficient bulk volume management

## Performance Considerations

### Concurrent Operations
- **Parallel Creation**: Multiple replicas created simultaneously
- **Async Processing**: Non-blocking operations with progress tracking
- **Resource Pooling**: Efficient reuse of connections and resources

### Optimization Strategies
- **Candidate Pre-Selection**: Pool candidates filtered before expensive operations
- **Batch Updates**: Multiple metadata updates combined for efficiency
- **State Caching**: Frequently accessed state cached to reduce etcd load

## Related Documentation
- **[[Mayastor Control Plane Architecture]]**: Overall control plane design
- **[[Mayastor Pool Selection and Scheduling]]**: Pool selection algorithms used in volume creation
- **[[Mayastor Metadata Storage and Persistence]]**: Metadata storage patterns
- **[[Mayastor IO Engine - Nexus Architecture]]**: How created replicas become nexus children
- **[[SPDK LVS Overview]]**: Underlying LVOL creation technology