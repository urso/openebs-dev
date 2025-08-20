---
title: Mayastor HA Switchover Process
type: note
permalink: mayastor/ha/mayastor-ha-switchover-process
---

# Mayastor HA Switchover Process

## Overview
Mayastor implements a 5-stage switchover orchestration with Write-Ahead Log (WAL) persistence to ensure exactly-once failover operations even during control plane failures.

## Switchover Architecture

### HA Cluster Agent (`controller/control-plane/agents/src/bin/ha/cluster/switchover.rs`)
```rust
pub struct SwitchoverExecutor {
    etcd_client: EtcdClient,           // Persistent state storage
    core_agent_client: CoreAgentClient, // Volume operations
    node_agent_clients: HashMap<String, NodeAgentClient>, // Path management
    worker_pool: Vec<SwitchoverWorker>, // 4 concurrent workers with retry logic
}
```

### Switchover Request Structure
```rust
pub struct SwitchoverRequest {
    pub id: SwitchoverId,              // Unique operation identifier
    pub volume_uuid: VolumeId,         // Target volume for switchover
    pub failed_node: String,           // io-engine node that failed
    pub target_node: Option<String>,   // Preferred replacement node
    pub requesting_client: String,     // Client node that detected failure
    pub trigger_reason: SwitchoverReason,
    pub created_at: DateTime<Utc>,
    pub stage: SwitchoverStage,        // Current progress stage
    pub retry_count: u32,              // Failure recovery tracking
}
```

## 5-Stage Switchover Process

### Stage 1: Init
**Purpose**: Create persistent switchover request for crash recovery
```rust
async fn stage_init(&mut self, request: &mut SwitchoverRequest) -> Result<(), SwitchoverError> {
    // Store initial request in etcd with TTL
    let key = format!("/mayastor/ha/switchover/{}", request.id);
    self.etcd_client
        .put_with_lease(key, serialize(request), SWITCHOVER_TTL)
        .await?;
    
    request.stage = SwitchoverStage::RepublishVolume;
    self.update_switchover_state(request).await?;
    
    info!("Switchover {} initialized for volume {}", request.id, request.volume_uuid);
    Ok(())
}
```

### Stage 2: RepublishVolume  
**Purpose**: Create new nexus on healthy node, gracefully shutdown old nexus
```rust
async fn stage_republish_volume(&mut self, request: &mut SwitchoverRequest) -> Result<(), SwitchoverError> {
    // Select target node using scheduler if not specified
    let target_node = match &request.target_node {
        Some(node) => node.clone(),
        None => self.select_target_node(&request.volume_uuid).await?,
    };
    
    // Create new nexus via Core Agent
    let republish_request = RepublishVolumeRequest {
        uuid: request.volume_uuid.clone(),
        target_node: target_node.clone(),
        share: Some(Protocol::Nvmf),      // Enable NVMe-oF sharing
        frontend_nodes: self.get_frontend_nodes(&request.volume_uuid).await?,
    };
    
    // This internally handles:
    // 1. Scheduler selects target node and suitable replicas
    // 2. New nexus created with NVMe reservations (prevents dual-active)
    // 3. Old nexus gracefully shutdown (reservations released)
    self.core_agent_client
        .republish_volume(republish_request)
        .await?;
    
    request.target_node = Some(target_node);
    request.stage = SwitchoverStage::ReplacePath;
    self.update_switchover_state(request).await?;
    
    Ok(())
}
```

### Stage 3: ReplacePath
**Purpose**: Update NVMe controller paths on all client nodes
```rust
async fn stage_replace_path(&mut self, request: &mut SwitchoverRequest) -> Result<(), SwitchoverError> {
    let new_nexus_endpoint = self.get_nexus_endpoint(&request.volume_uuid).await?;
    let old_nexus_endpoint = self.get_old_nexus_endpoint(&request.failed_node, &request.volume_uuid);
    
    // Update paths on all client nodes concurrently
    let mut update_tasks = Vec::new();
    
    for client_node in self.get_client_nodes(&request.volume_uuid).await? {
        let node_client = self.node_agent_clients.get(&client_node)
            .ok_or_else(|| SwitchoverError::NodeAgentUnavailable(client_node.clone()))?;
        
        let update_request = PathUpdateRequest {
            volume_uuid: request.volume_uuid.clone(),
            old_endpoint: old_nexus_endpoint.clone(),
            new_endpoint: new_nexus_endpoint.clone(),
            update_type: PathUpdateType::Replace,
        };
        
        let task = node_client.update_nvme_path(update_request);
        update_tasks.push(task);
    }
    
    // Wait for all path updates to complete
    futures::future::try_join_all(update_tasks).await?;
    
    request.stage = SwitchoverStage::DeleteTarget;
    self.update_switchover_state(request).await?;
    
    Ok(())
}
```

### Stage 4: DeleteTarget
**Purpose**: Clean up old nexus and NVMe subsystem from failed node
```rust
async fn stage_delete_target(&mut self, request: &mut SwitchoverRequest) -> Result<(), SwitchoverError> {
    // If failed node is reachable, gracefully destroy old nexus
    if let Some(failed_node_client) = self.io_engine_clients.get(&request.failed_node) {
        if failed_node_client.is_available().await {
            let destroy_request = DestroyNexusRequest {
                uuid: request.volume_uuid.clone(),
            };
            
            // Best effort cleanup - don't fail switchover if this fails
            if let Err(e) = failed_node_client.destroy_nexus(destroy_request).await {
                warn!("Failed to destroy old nexus on {}: {}", request.failed_node, e);
            }
        }
    }
    
    // Update Core Agent registry to reflect new nexus location
    self.core_agent_client
        .update_nexus_location(&request.volume_uuid, &request.target_node.as_ref().unwrap())
        .await?;
    
    request.stage = SwitchoverStage::Completion;
    self.update_switchover_state(request).await?;
    
    Ok(())
}
```

### Stage 5: Completion
**Purpose**: Finalize switchover and clean up persistent state
```rust
async fn stage_completion(&mut self, request: &mut SwitchoverRequest) -> Result<(), SwitchoverError> {
    // Generate success event
    let event = SwitchoverCompletionEvent {
        switchover_id: request.id.clone(),
        volume_uuid: request.volume_uuid.clone(),
        old_node: request.failed_node.clone(),
        new_node: request.target_node.as_ref().unwrap().clone(),
        duration: Utc::now().signed_duration_since(request.created_at),
        result: SwitchoverResult::Success,
    };
    
    self.event_publisher.publish(event).await?;
    
    // Remove switchover request from etcd
    let key = format!("/mayastor/ha/switchover/{}", request.id);
    self.etcd_client.delete(key).await?;
    
    info!("Switchover {} completed successfully for volume {}", 
          request.id, request.volume_uuid);
    
    Ok(())
}
```

## Write-Ahead Log (WAL) Implementation

### Persistent State Updates
```rust
async fn update_switchover_state(&self, request: &SwitchoverRequest) -> Result<(), SwitchoverError> {
    let key = format!("/mayastor/ha/switchover/{}", request.id);
    
    // Use Compare-and-Swap to prevent concurrent modifications
    self.etcd_client
        .put_cas(key, serialize(request), request.etcd_revision)
        .await?;
    
    debug!("Updated switchover {} to stage {:?}", request.id, request.stage);
    Ok(())
}
```

### Crash Recovery
```rust
pub async fn recover_incomplete_switchovers(&mut self) -> Result<(), SwitchoverError> {
    // Find all incomplete switchover requests on startup
    let prefix = "/mayastor/ha/switchover/";
    let incomplete_requests = self.etcd_client
        .get_range(prefix)
        .await?;
    
    for (key, value) in incomplete_requests {
        let mut request: SwitchoverRequest = deserialize(&value)?;
        
        warn!("Recovering incomplete switchover {} at stage {:?}", 
              request.id, request.stage);
        
        // Continue from last completed stage
        match request.stage {
            SwitchoverStage::Init => self.stage_init(&mut request).await?,
            SwitchoverStage::RepublishVolume => self.stage_republish_volume(&mut request).await?,
            SwitchoverStage::ReplacePath => self.stage_replace_path(&mut request).await?,
            SwitchoverStage::DeleteTarget => self.stage_delete_target(&mut request).await?,
            SwitchoverStage::Completion => self.stage_completion(&mut request).await?,
        }
    }
    
    Ok(())
}
```

## Worker Pool Architecture

### Concurrent Execution
```rust
pub struct SwitchoverWorker {
    worker_id: u32,
    request_queue: mpsc::Receiver<SwitchoverRequest>,
    executor: SwitchoverExecutor,
    max_concurrent: usize,             // Default: 4 workers
    retry_policy: RetryPolicy,         // Exponential backoff
}

impl SwitchoverWorker {
    async fn run(&mut self) {
        while let Some(request) = self.request_queue.recv().await {
            let result = self.execute_with_retry(request).await;
            
            match result {
                Ok(_) => info!("Switchover {} completed by worker {}", 
                              request.id, self.worker_id),
                Err(e) => error!("Switchover {} failed: {}", request.id, e),
            }
        }
    }
}
```

### Retry Logic
```rust
async fn execute_with_retry(&mut self, mut request: SwitchoverRequest) -> Result<(), SwitchoverError> {
    let mut retry_count = 0;
    let max_retries = self.retry_policy.max_retries;
    
    loop {
        match self.execute_switchover(&mut request).await {
            Ok(_) => return Ok(()),
            Err(e) if retry_count < max_retries && e.is_retryable() => {
                retry_count += 1;
                request.retry_count = retry_count;
                
                let delay = self.retry_policy.delay_for_attempt(retry_count);
                warn!("Switchover {} failed, retrying in {:?}: {}", 
                      request.id, delay, e);
                
                tokio::time::sleep(delay).await;
                continue;
            }
            Err(e) => {
                error!("Switchover {} failed permanently after {} retries: {}", 
                       request.id, retry_count, e);
                return Err(e);
            }
        }
    }
}
```

## Integration with Data Plane

### NVMe Reservation Coordination
The switchover process relies on NVMe reservations for split-brain prevention:

1. **New nexus creation**: Attempts to acquire WriteExclusiveAllRegs reservation
2. **Successful acquisition**: Indicates old nexus has released or failed
3. **Failed acquisition**: Triggers reservation preemption if old nexus is confirmed dead
4. **Graceful shutdown**: Old nexus releases reservations before destruction

### ANA State Management
```rust
// During path replacement, ANA states are updated:
// Old path: OptimizedState → InaccessibleState  
// New path: InaccessibleState → OptimizedState
// This enables seamless NVMe multipath failover
```

## Error Handling

### Switchover Failure Types
```rust
pub enum SwitchoverError {
    TargetNodeUnavailable(String),     // No suitable replacement node
    ReservationConflict(VolumeId),     // Can't acquire NVMe reservations  
    PathUpdateTimeout(String),         // Client node path update failed
    CoreAgentUnavailable,              // Can't reach volume management API
    EtcdOperationFailed(String),       // Persistent state operation failed
}
```

### Rollback Mechanisms
- **Partial completion**: WAL enables resuming from last successful stage
- **Reservation conflicts**: Automatic preemption with confirmation policies
- **Client path failures**: Retry with exponential backoff, eventual manual intervention

## Performance Characteristics

### Switchover Timing
- **Stage 1-2**: ~2-5 seconds (etcd operations + nexus creation)
- **Stage 3**: ~1-3 seconds (NVMe path updates on client nodes)
- **Stage 4-5**: ~1-2 seconds (cleanup + event generation)
- **Total**: ~5-15 seconds typical, depending on cluster size

### Scalability
- **Concurrent switchovers**: 4 worker threads handle multiple volumes simultaneously
- **Client nodes**: Parallel path updates across all affected clients
- **Cluster size**: Performance degrades linearly with number of client nodes per volume

## Source Code Locations
- **Main orchestrator**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs`
- **Worker pool**: `controller/control-plane/agents/src/bin/ha/cluster/worker.rs`
- **WAL recovery**: `controller/control-plane/agents/src/bin/ha/cluster/recovery.rs`
- **Core agent integration**: `controller/control-plane/agents/src/bin/core/volume/operations.rs:589-634`
- **Node agent coordination**: `controller/control-plane/agents/src/bin/ha/node/path_manager.rs`