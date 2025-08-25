---
title: CSI Driver Overview
type: note
permalink: mayastor/csi-driver/csi-driver-overview
---

# CSI Driver Overview

## Architecture Overview

Mayastor's **CSI (Container Storage Interface) driver** provides a standardized interface between Kubernetes and Mayastor's storage system. The driver implements the CSI specification to handle volume lifecycle operations, including creation, deletion, snapshotting, and restoration, while translating these operations into Mayastor's native APIs.

**Related Documentation**: See [[Mayastor IO Engine - Volume Snapshot Architecture]] for underlying snapshot implementation and [[Mayastor Volume Lifecycle Management]] for volume operations.

## Code Architecture

### Main Components

**CSI Controller** (`control-plane/csi-driver/src/bin/controller/controller.rs`):
- Implements CSI Controller service gRPC interface
- Handles volume and snapshot lifecycle operations
- Coordinates with Mayastor control plane via REST API

**REST API Client** (`control-plane/csi-driver/src/bin/controller/client.rs`):
- Wraps control plane REST API calls
- Provides typed interfaces for volume and snapshot operations
- Handles error translation between REST and CSI domains

**Context Parsing** (`control-plane/csi-driver/src/context.rs`):
- Parses and validates CSI parameters from storage classes
- Converts Kubernetes topology requirements to Mayastor placement
- Handles snapshot-specific parameters like filesystem quiescing

**Node Plugin** (`control-plane/csi-driver/src/node/`):
- Implements CSI Node service for volume mounting/unmounting
- Provides filesystem quiescing capabilities for application-consistent snapshots
- Handles block device and filesystem operations

### CSI Service Implementation

**Controller Service Interface** (`controller.rs:80-120`):
```rust
#[tonic::async_trait]
impl Controller for ControllerSvc {
    // Volume operations
    async fn create_volume(&self, ...) -> Result<Response<CreateVolumeResponse>, Status>
    async fn delete_volume(&self, ...) -> Result<Response<DeleteVolumeResponse>, Status>
    
    // Snapshot operations  
    async fn create_snapshot(&self, ...) -> Result<Response<CreateSnapshotResponse>, Status>
    async fn delete_snapshot(&self, ...) -> Result<Response<DeleteSnapshotResponse>, Status>
    async fn list_snapshots(&self, ...) -> Result<Response<ListSnapshotsResponse>, Status>
    
    // Additional operations
    async fn controller_expand_volume(&self, ...) -> Result<Response<ControllerExpandVolumeResponse>, Status>
    async fn validate_volume_capabilities(&self, ...) -> Result<Response<ValidateVolumeCapabilitiesResponse>, Status>
}
```

## gRPC to REST API Translation Flow

### Volume Operations

**CSI CreateVolumeRequest Flow** (`controller.rs:320-480`):
```
1. CSI gRPC Request
   ↓ controller.rs:create_volume() [line 320]
2. Parameter Parsing  
   ↓ context.rs:CreateParams::try_from() [line 450]
3. REST API Call
   ↓ client.rs:create_volume() [line 250] OR client.rs:create_snapshot_volume() [line 298]
4. Control Plane Processing
   ↓ REST API → volume/operations.rs OR volume/clone_operations.rs
5. CSI Response Generation
   ↓ controller.rs CreateVolumeResponse [line 470]
```

**Volume Source Detection** (`controller.rs:380-420`):
```rust
let volume_content_source = if let Some(source) = &args.volume_content_source {
    match &source.r#type {
        Some(Type::Snapshot(snapshot_source)) => {
            let snapshot_uuid = Uuid::parse_str(&snapshot_source.snapshot_id)?;
            Some(snapshot_uuid)
        }
        Some(Type::Volume(_)) => {
            return Err(Status::invalid_argument(
                "Volume creation from volume source is not supported",
            ));
        }
        _ => None,
    }
} else {
    None
};
```

### Snapshot Operations

**CSI CreateSnapshotRequest Flow** (`controller.rs:950-1050`):
```
1. CSI gRPC Request
   ↓ controller.rs:create_snapshot() [line 950] 
2. UUID Extraction & Validation
   ↓ Extract UUID from CSI name format "snapshot-{uuid}" [line 975]
3. Optional Filesystem Quiescing
   ↓ issue_fs_freeze() [line 190] → Node Plugin gRPC
4. REST API Call  
   ↓ client.rs:create_volume_snapshot() [line 410]
5. Control Plane Snapshot Creation
   ↓ REST API → control-plane/agents/.../volume/snapshot_operations.rs
6. Optional Filesystem Unfreeze
   ↓ issue_fs_unfreeze() [line 250] → Node Plugin gRPC  
7. CSI Response Generation
   ↓ snapshot_to_csi() [line 1580] → CreateSnapshotResponse
```

## Data Structure Mappings

### CSI to Mayastor Type Conversions

**Volume Creation Parameters** (`context.rs:450-550`):
```rust
pub struct CreateParams {
    pub repl: u8,                          // → CreateVolumeBody.replicas
    pub protocol: VolumeShareProtocol,     // → Volume sharing configuration  
    pub thin: bool,                        // → CreateVolumeBody.thin
    pub cluster: Option<u64>,              // → CreateVolumeBody.cluster_size
    // ... topology, affinity group, encryption
}
```

**Snapshot Parameters** (`context.rs:620-650`):
```rust
pub struct CreateSnapshotParams {
    queisce: Option<QuiesceFsCandidate>,   // → Filesystem quiescing behavior
}

pub enum QuiesceFsCandidate {
    None,    // No filesystem quiescing
    Freeze,  // Linux freeze/unfreeze syscalls
}
```

**CSI Snapshot Response Mapping** (`controller.rs:1580-1600`):
```rust
fn snapshot_to_csi(snapshot: models::VolumeSnapshot) -> Snapshot {
    Snapshot {
        size_bytes: snapshot.definition.metadata.spec_size as i64,           // Required for clone sizing
        snapshot_id: snapshot.definition.spec.uuid.to_string(),             // Mayastor snapshot UUID  
        source_volume_id: snapshot.definition.spec.source_volume.to_string(), // Source volume UUID
        creation_time: snapshot.definition.metadata.timestamp               // ISO8601 timestamp
            .and_then(|t| prost_types::Timestamp::from_str(&t).ok()),
        ready_to_use: snapshot.definition.metadata.status == models::SpecStatus::Created,
        group_snapshot_id: "".to_string(),  // Not implemented yet
    }
}
```

## Error Handling Architecture

### Error Translation Pipeline

**API Client Error Mapping** (`client.rs:100-150`):
```rust
impl From<openapi::Error<T>> for ApiClientError {
    fn from(error: openapi::Error<T>) -> Self {
        match error {
            openapi::Error::Reqwest(e) => ApiClientError::RequestError(e.to_string()),
            openapi::Error::Serde(e) => ApiClientError::DeserializationError(e.to_string()),
            openapi::Error::Io(e) => ApiClientError::IoError(e.to_string()),
            openapi::Error::ResponseError(content) => {
                // Parse HTTP status codes to appropriate API errors
                match content.status {
                    reqwest::StatusCode::NOT_FOUND => ApiClientError::ResourceNotExists(content.entity),
                    reqwest::StatusCode::CONFLICT => ApiClientError::PreconditionFailed(content.entity),
                    reqwest::StatusCode::INSUFFICIENT_STORAGE => ApiClientError::ResourceExhausted(content.entity),
                    _ => ApiClientError::UnexpectedError(content.entity),
                }
            }
        }
    }
}
```

**CSI Status Code Translation** (`controller.rs:1000-1020`):
```rust
.map_err(|error| match error {
    ApiClientError::ResourceExhausted(reason) => {
        Status::resource_exhausted(reason)         // CSI: RESOURCE_EXHAUSTED
    }
    ApiClientError::PreconditionFailed(reason) => {
        Status::resource_exhausted(reason)         // CSI: RESOURCE_EXHAUSTED (same mapping)
    }
    ApiClientError::ResourceNotExists(reason) => {
        Status::not_found(reason)                  // CSI: NOT_FOUND
    }
    error => Status::internal(error.to_string()), // CSI: INTERNAL (generic)
})
```

## Concurrency and Safety

### Volume Operation Guards

**Concurrency Prevention** (`controller.rs:960`):
```rust
let _guard = csi_driver::limiter::VolumeOpGuard::new(volume_uuid)?;
```

**Implementation** (`csi-driver/src/limiter.rs`):
- Prevents concurrent operations on same volume UUID
- Uses `tokio::sync::Mutex` for async-safe locking
- Guards both volume creation and snapshot operations
- Automatically releases on guard drop

### Idempotency Handling

**Snapshot Creation Idempotency** (`controller.rs:980-1000`):
```rust
// Check if snapshot already exists (idempotency)
match RestApiClient::get_client()
    .get_volume_snapshot(&snap_uuid)
    .await
{
    Ok(snapshot) => Ok(snapshot),                    // Return existing snapshot
    Err(ApiClientError::ResourceNotExists(_)) => {
        // Create new snapshot
        RestApiClient::get_client()
            .create_volume_snapshot(&volume_uuid, &snap_uuid)
            .await
    }
    Err(error) => Err(error),                        // Propagate other errors
}
```

## Node Plugin Integration

### Filesystem Quiescing

**Node Plugin Communication** (`controller.rs:190-240`):
```rust
async fn issue_fs_freeze(endpoint: String, volume_id: String) -> Result<(), Status> {
    let channel = tonic_endpoint(format!("http://{endpoint}"))?
        .connect()
        .await?;
    let mut client = NodePluginClient::new(channel);
    
    client.freeze_fs(Request::new(FreezeFsRequest {
        volume_id: volume_id.clone(),
    })).await
}
```

**Node Plugin Service** (`node/internal/mod.rs`):
- Implements internal gRPC service for CSI controller → node communication
- Handles filesystem freeze/unfreeze operations
- Provides volume staging/publishing status information
- Supports force unstaging for cleanup operations

## Configuration and Deployment

### CSI Driver Registration

**Driver Capabilities** (`controller.rs:60-80`):
```rust
impl ControllerSvc {
    pub fn new(config: CsiControllerConfig) -> Self {
        // Registers CSI controller capabilities:
        // - CREATE_DELETE_VOLUME
        // - CREATE_DELETE_SNAPSHOT  
        // - LIST_SNAPSHOTS
        // - EXPAND_VOLUME
        // - CLONE_VOLUME (via snapshot source)
    }
}
```

**Storage Class Parameters** (`context.rs:Parameters`):
```rust
pub enum Parameters {
    Protocol,                    // "nvmf" | "iscsi" 
    Replicas,                   // "1" | "2" | "3"
    Thin,                       // "true" | "false"
    QuesceFs,                   // "none" | "freeze"
    MaxSnapshots,               // Maximum snapshots per volume
    Encrypted,                  // Volume encryption
    PoolAffinityTopologyLabel,  // Pool placement constraints
    NodeAffinityTopologyLabel,  // Node placement constraints
    // ... additional topology and affinity parameters
}
```

## Testing and Validation

### BDD Test Structure

**CSI Snapshot Tests** (`tests/bdd/features/snapshot/csi/controller/test_operations.py`):
- End-to-end CSI snapshot workflow validation
- Volume restoration from snapshots testing  
- Error condition and idempotency testing
- Performance and concurrency testing

**Test Scenarios**:
- Basic snapshot creation and deletion
- Volume cloning from snapshots
- Filesystem quiescing with various backends
- Error handling and recovery
- Concurrent operation handling

## Source Code Organization

### Key Files and Their Responsibilities

**Controller Implementation**:
- `controller.rs`: Main CSI Controller service implementation (1200+ lines)
- `client.rs`: REST API client wrapper (400+ lines)
- `context.rs`: Parameter parsing and validation (800+ lines)

**Node Plugin**:
- `node/controller.rs`: CSI Node service implementation
- `node/internal/`: Internal services for controller-node communication
- `node/mount.rs`: Volume mounting and filesystem operations

**Shared Utilities**:
- `limiter.rs`: Concurrency control and volume operation guards
- `trace.rs`: Request tracing and observability
- `identity.rs`: CSI driver identity and capabilities

**Configuration**:
- `config.rs`: CSI driver configuration structures
- `dev/mod.rs`: Development and testing utilities

**Build and Deployment**:
- `chart/`: Helm chart for Kubernetes deployment
- `chart/charts/crds/templates/`: Kubernetes CRD definitions for snapshots

## Performance Considerations

### Critical Path Analysis

**Snapshot Creation Latency**:
1. **CSI gRPC processing**: ~1-5ms (minimal overhead)
2. **Filesystem quiescing**: ~100-500ms (if enabled, depends on filesystem)
3. **REST API call**: ~10-50ms (network + control plane processing)
4. **Multi-replica coordination**: ~50-200ms (depends on replica count and network)
5. **SPDK snapshot creation**: ~5-10ms per replica (very fast)

**Volume Creation from Snapshot**:
1. **CSI parameter parsing**: ~1-5ms
2. **Clone creation**: ~100-500ms (depends on snapshot replica availability)
3. **Nexus construction**: ~200-1000ms (network topology dependent)

### Optimization Strategies

**Caching and Batching**:
- REST client connection pooling for reduced latency
- Parameter validation caching for repeated operations
- Batch snapshot operations where possible (future enhancement)

**Error Path Optimization**:
- Fast-fail validation before expensive operations
- Idempotency checks to avoid duplicate work
- Graceful degradation for partial failures

This overview provides the foundation for understanding Mayastor's CSI integration. Each component links to more detailed documentation covering specific implementation aspects.