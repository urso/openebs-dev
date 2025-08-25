---
title: Advanced Features
type: note
permalink: mayastor/csi-driver/advanced-features
---

# Advanced Features

## Overview

This document covers advanced CSI driver features that developers need to understand for extending functionality, debugging complex scenarios, or integrating with other Mayastor components. These features go beyond basic volume and snapshot operations to provide enterprise-grade capabilities and integration points.

**Related Documentation**: See [[CSI Driver Overview]] for architecture and [[Kubernetes Snapshot Integration]] for snapshot implementation details.

## Filesystem Quiescing System

### Node Plugin Communication Infrastructure

**Internal gRPC Service Definition** (`node/internal/mod.rs:20-40`):
```rust
pub mod node_plugin_server {
    use super::*;
    
    pub trait NodePlugin: Send + Sync + 'static {
        async fn freeze_fs(
            &self,
            request: tonic::Request<FreezeFsRequest>,
        ) -> Result<tonic::Response<FreezeFsResponse>, tonic::Status>;
        
        async fn unfreeze_fs(
            &self,
            request: tonic::Request<UnfreezeFsRequest>,
        ) -> Result<tonic::Response<UnfreezeFsResponse>, tonic::Status>;
        
        async fn force_unstage_volume(
            &self,
            request: tonic::Request<ForceUnstageVolumeRequest>,
        ) -> Result<tonic::Response<ForceUnstageVolumeResponse>, tonic::Status>;
    }
}
```

**Controller to Node Communication** (`controller.rs:190-240`):
```rust
async fn issue_fs_freeze(endpoint: String, volume_id: String) -> Result<(), Status> {
    trace!("Issuing fs freeze");
    let channel = tonic_endpoint(format!("http://{endpoint}"))?
        .connect()
        .await
        .map_err(|error| Status::unavailable(error.to_string()))?;
    let mut client = NodePluginClient::new(channel);

    match client
        .freeze_fs(Request::new(FreezeFsRequest {
            volume_id: volume_id.clone(),
        }))
        .await
    {
        Ok(_) => Ok(()),
        Err(status) if status.code() == tonic::Code::InvalidArgument => {
            trace!("fs freeze not supported for raw block volume: {volume_id}");
            Ok(())  // Raw block volumes silently ignore freeze requests
        }
        Err(error) => Err(error),
    }
}
```

### Filesystem-Specific Freeze Implementation

**Node Plugin Freeze Handler** (`node/controller.rs:380-420`):
```rust
async fn freeze_fs(
    &self,
    request: tonic::Request<FreezeFsRequest>,
) -> Result<tonic::Response<FreezeFsResponse>, tonic::Status> {
    let req = request.into_inner();
    let volume_id = req.volume_id;
    
    // Locate mounted volume by UUID
    let mount_info = self.find_mount_by_volume_id(&volume_id)
        .await
        .map_err(|e| Status::not_found(format!("Volume not mounted: {}", e)))?;
        
    match mount_info.fs_type.as_str() {
        "ext4" | "ext3" | "ext2" => {
            self.freeze_ext_filesystem(&mount_info.mount_path).await?
        }
        "xfs" => {
            self.freeze_xfs_filesystem(&mount_info.mount_path).await?
        }
        "btrfs" => {
            self.freeze_btrfs_filesystem(&mount_info.mount_path).await?
        }
        _ => {
            return Err(Status::invalid_argument(format!(
                "Filesystem type {} does not support freezing", 
                mount_info.fs_type
            )));
        }
    }
    
    Ok(tonic::Response::new(FreezeFsResponse {}))
}
```

**Filesystem Operations Implementation** (`node/filesystem.rs:100-180`):
```rust
impl FilesystemOperations {
    async fn freeze_ext_filesystem(&self, mount_path: &str) -> Result<(), Status> {
        // Use Linux FIFREEZE ioctl via system call
        let fd = unsafe {
            libc::open(
                CString::new(mount_path)?.as_ptr(),
                libc::O_RDONLY,
            )
        };
        
        if fd < 0 {
            return Err(Status::internal("Failed to open filesystem for freeze"));
        }
        
        let result = unsafe {
            libc::ioctl(fd, libc::FIFREEZE)  // Freeze filesystem
        };
        
        unsafe { libc::close(fd) };
        
        if result < 0 {
            Err(Status::internal("Filesystem freeze ioctl failed"))
        } else {
            info!("Successfully froze filesystem at {}", mount_path);
            Ok(())
        }
    }
    
    async fn freeze_xfs_filesystem(&self, mount_path: &str) -> Result<(), Status> {
        // XFS uses xfs_freeze utility
        let output = Command::new("xfs_freeze")
            .arg("-f")  // Freeze
            .arg(mount_path)
            .output()
            .await
            .map_err(|e| Status::internal(format!("xfs_freeze command failed: {}", e)))?;
            
        if !output.status.success() {
            return Err(Status::internal(format!(
                "xfs_freeze failed: {}", 
                String::from_utf8_lossy(&output.stderr)
            )));
        }
        
        info!("Successfully froze XFS filesystem at {}", mount_path);
        Ok(())
    }
    
    async fn unfreeze_ext_filesystem(&self, mount_path: &str) -> Result<(), Status> {
        let fd = unsafe {
            libc::open(
                CString::new(mount_path)?.as_ptr(),
                libc::O_RDONLY,
            )
        };
        
        if fd < 0 {
            return Err(Status::internal("Failed to open filesystem for unfreeze"));
        }
        
        let result = unsafe {
            libc::ioctl(fd, libc::FITHAW)  // Unfreeze filesystem
        };
        
        unsafe { libc::close(fd) };
        
        if result < 0 {
            Err(Status::internal("Filesystem unfreeze ioctl failed"))
        } else {
            info!("Successfully unfroze filesystem at {}", mount_path);
            Ok(())
        }
    }
}
```

### Mount Tracking System

**Volume Mount Discovery** (`node/mount_tracker.rs:50-100`):
```rust
pub struct MountTracker {
    active_mounts: Arc<RwLock<HashMap<String, MountInfo>>>,
}

pub struct MountInfo {
    pub volume_uuid: String,
    pub mount_path: String,
    pub fs_type: String,
    pub mount_options: Vec<String>,
    pub staging_path: String,
    pub published_path: String,
    pub mount_time: SystemTime,
}

impl MountTracker {
    pub async fn find_mount_by_volume_id(&self, volume_id: &str) -> Option<MountInfo> {
        let mounts = self.active_mounts.read().await;
        mounts.get(volume_id).cloned()
    }
    
    pub async fn register_mount(&self, mount_info: MountInfo) {
        let mut mounts = self.active_mounts.write().await;
        info!("Registering mount for volume {} at {}", 
              mount_info.volume_uuid, mount_info.mount_path);
        mounts.insert(mount_info.volume_uuid.clone(), mount_info);
    }
    
    pub async fn unregister_mount(&self, volume_id: &str) -> Option<MountInfo> {
        let mut mounts = self.active_mounts.write().await;
        info!("Unregistering mount for volume {}", volume_id);
        mounts.remove(volume_id)
    }
}
```

### Critical Error Coordination

**Freeze/Unfreeze Error Handling** (`controller.rs:1050-1080`):
```rust
// Always unfreeze the filesystem if quiesce was requested, as the retry mechanism can
// leave filesystem frozen.
let snapshot = if let Some(app_node_endpoint) = app_node_endpoint_info {
    let unfreeze_result =
        issue_fs_unfreeze(app_node_endpoint, volume_uuid.to_string()).await;
    match (snapshot_creation_result, unfreeze_result) {
        (result, Ok(())) => result,
        (Ok(_snapshot), Err(unfreeze_error)) => Err(Status::failed_precondition(format!(
            "Snapshot creation succeeded but filesystem unfreeze failed: {}",
            unfreeze_error
        ))),
        (Err(snap_error), Err(unfreeze_error)) => {
            Err(Status::failed_precondition(format!(
                "Snapshot creation failed: {}, filesystem unfreeze failed: {}",
                snap_error, unfreeze_error
            )))
        }
    }
} else {
    snapshot_creation_result
}?;
```

**Critical Developer Notes**:
- **Unfreeze failure is critical**: If snapshot succeeds but unfreeze fails, filesystem remains frozen
- **Manual intervention required**: Frozen filesystems require operator intervention to recover
- **Always attempt unfreeze**: Even if snapshot fails, must attempt to unfreeze

## Volume Operation Concurrency Control

### VolumeOpGuard Implementation

**Global Per-Volume Mutex System** (`limiter.rs:20-80`):
```rust
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, OwnedMutexGuard};
use uuid::Uuid;

pub struct VolumeOpGuard {
    _guard: OwnedMutexGuard<()>,
    volume_uuid: Uuid,
}

static VOLUME_LOCKS: once_cell::sync::Lazy<Arc<Mutex<HashMap<Uuid, Arc<Mutex<()>>>>>> =
    once_cell::sync::Lazy::new(|| Arc::new(Mutex::new(HashMap::new())));

impl VolumeOpGuard {
    pub async fn new(volume_uuid: Uuid) -> Result<Self, tonic::Status> {
        let volume_lock = {
            let mut locks = VOLUME_LOCKS.lock().await;
            locks
                .entry(volume_uuid)
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        
        // Acquire exclusive lock for this volume
        let guard = volume_lock
            .lock_owned()
            .await;
            
        trace!("Acquired volume operation lock for {}", volume_uuid);
        
        Ok(VolumeOpGuard {
            _guard: guard,
            volume_uuid,
        })
    }
}

impl Drop for VolumeOpGuard {
    fn drop(&mut self) {
        trace!("Released volume operation lock for {}", self.volume_uuid);
        // Lock automatically released when guard is dropped
    }
}
```

**Usage Pattern Across CSI Operations** (`controller.rs:960, controller.rs:1260`):
```rust
// Snapshot creation
let _guard = csi_driver::limiter::VolumeOpGuard::new(volume_uuid)?;

// Volume expansion  
let _guard = csi_driver::limiter::VolumeOpGuard::new(volume_uuid)?;

// Volume deletion
let _guard = csi_driver::limiter::VolumeOpGuard::new(volume_uuid)?;
```

**Deadlock Prevention Strategy**:
- **Single lock per volume**: No nested or hierarchical locking
- **UUID-based ordering**: Consistent lock acquisition order prevents circular dependencies
- **Cross-volume independence**: Operations on different volumes never block each other
- **Automatic cleanup**: RAII pattern ensures locks are always released

### Lock Scope and Serialization

**Serialized Operations Per Volume**:
1. **Volume creation** (`create_volume`)
2. **Volume deletion** (`delete_volume`) 
3. **Snapshot creation** (`create_snapshot`)
4. **Snapshot deletion** (`delete_snapshot`)
5. **Volume expansion** (`controller_expand_volume`)
6. **Clone creation** (via `create_volume` with snapshot source)

**Parallel Operations**:
- **Different volumes**: Can operate completely in parallel
- **Read operations**: `list_snapshots`, `get_capacity` don't acquire locks
- **Node operations**: Volume mounting/unmounting on nodes is independent

## Distributed Tracing Infrastructure

### Request Correlation System

**Span Creation and Management** (`trace.rs:30-70`):
```rust
pub struct CsiRequest {
    operation: String,
    start_time: Instant,
    span: tracing::Span,
}

impl CsiRequest {
    pub fn new_info(operation: &str) -> Self {
        let span = tracing::info_span!(
            "csi_request",
            operation = operation,
            request_id = %Uuid::new_v4(),
        );
        
        Self {
            operation: operation.to_string(),
            start_time: Instant::now(),
            span,
        }
    }
    
    pub fn info_ok(&self) {
        let duration = self.start_time.elapsed();
        tracing::info!(
            parent: &self.span,
            duration_ms = duration.as_millis(),
            result = "success",
            "CSI request completed"
        );
    }
    
    pub fn error_with_details(&self, error: &dyn std::error::Error) {
        let duration = self.start_time.elapsed();
        tracing::error!(
            parent: &self.span,
            duration_ms = duration.as_millis(),
            result = "error",
            error = %error,
            "CSI request failed"
        );
    }
}
```

**Automatic Span Propagation** (`controller.rs:950-960`):
```rust
#[instrument(err, fields(
    volume.uuid = request.get_ref().source_volume_id, 
    snapshot.source_uuid = request.get_ref().source_volume_id, 
    snapshot.uuid
), skip(self))]
async fn create_snapshot(
    &self,
    request: tonic::Request<CreateSnapshotRequest>,
) -> Result<tonic::Response<CreateSnapshotResponse>, tonic::Status>
```

**Dynamic Span Updates** (`controller.rs:985`):
```rust
// Update tracing span with extracted snapshot UUID
tracing::Span::current().record("snapshot.uuid", snap_uuid.as_str());
```

### Cross-Component Trace Correlation

**REST API Client Tracing** (`client.rs:410-420`):
```rust
#[instrument(fields(snapshot.uuid = %snapshot_id), skip(self, volume_id, snapshot_id))]
pub(crate) async fn create_volume_snapshot(
    &self,
    volume_id: &uuid::Uuid,
    snapshot_id: &uuid::Uuid,
) -> Result<models::VolumeSnapshot, ApiClientError> {
    let snapshot = self
        .rest_client
        .snapshots_api()
        .put_volume_snapshot(volume_id, snapshot_id)
        .await?;

    Ok(snapshot.into_body())
}
```

**Performance Monitoring Integration** (`controller.rs:470-480`):
```rust
// Automatic performance logging
tracing::info!(
    size_bytes = size,
    replica_count = replica_count,
    thin = thin,
    duration_ms = req.start_time.elapsed().as_millis(),
    volume.uuid = %parsed_vol_uuid,
    "{}",
    req.log_str()
);
```

**Error Context Preservation**:
```rust
// All errors automatically include full context chain
#[instrument(err, fields(volume.uuid = %volume_id), skip(self))]
pub async fn create_volume(...) -> Result<Volume, ApiClientError> {
    // Any error here includes volume UUID, function context, and error chain
}
```

## CSI Extension Points and Capabilities

### Dynamic Capability Advertisement

**Controller Service Capabilities** (`controller.rs:60-80`):
```rust
impl ControllerSvc {
    pub fn get_capabilities() -> Vec<ControllerServiceCapability> {
        vec![
            // Basic volume operations
            controller_capability(ControllerServiceCapability::Rpc::CreateDeleteVolume),
            
            // Snapshot operations  
            controller_capability(ControllerServiceCapability::Rpc::CreateDeleteSnapshot),
            controller_capability(ControllerServiceCapability::Rpc::ListSnapshots),
            
            // Advanced features
            controller_capability(ControllerServiceCapability::Rpc::CloneVolume),
            controller_capability(ControllerServiceCapability::Rpc::ExpandVolume),
            
            // Future capabilities (when implemented)
            // controller_capability(ControllerServiceCapability::Rpc::CreateDeleteVolumeGroupSnapshot),
        ]
    }
    
    fn controller_capability(
        rpc_type: ControllerServiceCapability::Rpc::Type
    ) -> ControllerServiceCapability {
        ControllerServiceCapability {
            r#type: Some(controller_service_capability::Type::Rpc(
                controller_service_capability::Rpc {
                    r#type: rpc_type as i32,
                }
            )),
        }
    }
}
```

**Node Service Capabilities** (`node/controller.rs:100-130`):
```rust
impl NodeSvc {
    pub fn get_capabilities() -> Vec<NodeServiceCapability> {
        vec![
            // Volume staging/publishing
            node_capability(NodeServiceCapability::Rpc::StageUnstageVolume),
            
            // Volume expansion on node
            node_capability(NodeServiceCapability::Rpc::ExpandVolume),
            
            // Monitoring and health
            node_capability(NodeServiceCapability::Rpc::GetVolumeStats),
            node_capability(NodeServiceCapability::Rpc::VolumeCondition),
            
            // Advanced features
            node_capability(NodeServiceCapability::Rpc::VolumeMount),
        ]
    }
}
```

### Volume Expansion Support

**Controller-Side Expansion** (`controller.rs:1250-1300`):
```rust
#[instrument(err, fields(volume.uuid = request.get_ref().volume_id), skip(self))]
async fn controller_expand_volume(
    &self,
    request: tonic::Request<ControllerExpandVolumeRequest>,
) -> Result<tonic::Response<ControllerExpandVolumeResponse>, tonic::Status> {
    let req = csi_driver::trace::CsiRequest::new_info("Expand Volume");
    let args = request.into_inner();

    let volume_uuid = Uuid::parse_str(&args.volume_id)?;
    let _guard = csi_driver::limiter::VolumeOpGuard::new(volume_uuid)?;
    
    let requested_size = args.capacity_range
        .map(|range| range.required_bytes as u64)
        .unwrap_or(0);

    // Expand volume via control plane (resizes all replicas)
    let vol = RestApiClient::get_client()
        .expand_volume(&volume_uuid, requested_size)
        .await
        .map_err(|error| match error {
            ApiClientError::PreconditionFailed(msg) => Status::internal(msg),
            ApiClientError::ResourceExhausted(msg) => Status::resource_exhausted(msg),
            error => Status::from(error),
        })?;

    // Determine if node expansion is required (filesystem resize)
    let node_expansion_required = vol.spec.target_size > vol.status.size;

    tracing::info!(size_bytes = requested_size, "{}", req.log_str());
    Ok(tonic::Response::new(ControllerExpandVolumeResponse {
        capacity_bytes: vol.spec.target_size as i64,
        node_expansion_required,
    }))
}
```

**Future Extension Framework** (architectural planning):
```rust
// Plugin interface for extending CSI functionality
pub trait CsiExtension: Send + Sync {
    async fn pre_create_volume(
        &self,
        request: &CreateVolumeRequest,
    ) -> Result<(), tonic::Status>;
    
    async fn post_create_volume(
        &self,
        request: &CreateVolumeRequest,
        response: &CreateVolumeResponse,
    ) -> Result<(), tonic::Status>;
    
    // Similar hooks for other operations
}
```

## Control Plane Integration Complexities

### REST Client Connection Management

**HTTP/2 Connection Optimization** (`client.rs:80-120`):
```rust
pub struct RestApiClient {
    rest_client: Arc<dyn OpenApi>,
    timeout: Duration,
}

impl RestApiClient {
    pub fn new(endpoint: Uri, timeout: Duration) -> Self {
        let configuration = Configuration {
            base_path: endpoint.to_string(),
            user_agent: Some("mayastor-csi-controller/1.0".to_string()),
            client: reqwest::Client::builder()
                .timeout(timeout)
                .tcp_keepalive(Duration::from_secs(30))            // TCP keepalive
                .http2_keep_alive_interval(Duration::from_secs(10)) // HTTP/2 ping frames
                .http2_keep_alive_timeout(Duration::from_secs(30))  // HTTP/2 timeout
                .http2_adaptive_window(true)                        // Flow control optimization
                .pool_max_idle_per_host(10)                        // Connection pooling
                .build()
                .expect("Failed to create HTTP client"),
            basic_auth: None,
            oauth_access_token: None,
            bearer_access_token: None,
            api_key: None,
        };
        
        Self {
            rest_client: Arc::new(
                stor_port::types::v0::openapi::apis::client::APIClient::new(configuration)
            ),
            timeout,
        }
    }
}
```

### Error Translation Architecture

**Multi-Layer Error Handling** (`client.rs:150-200`):
```rust
impl RestApiClient {
    async fn delete_idempotent<T>(
        result: Result<openapi::ResponseContent<T>, openapi::Error<T>>,
        allow_not_found: bool,
    ) -> Result<bool, ApiClientError> {
        match result {
            Ok(_) => Ok(true),
            Err(openapi::Error::ResponseError(content)) => {
                match content.status {
                    reqwest::StatusCode::NOT_FOUND if allow_not_found => {
                        warn!("Resource not found during delete operation (idempotent)");
                        Ok(false)  // Success: resource was already deleted
                    }
                    reqwest::StatusCode::CONFLICT => {
                        Err(ApiClientError::PreconditionFailed(content.entity))
                    }
                    reqwest::StatusCode::INSUFFICIENT_STORAGE => {
                        Err(ApiClientError::ResourceExhausted(content.entity))
                    }
                    _ => {
                        Err(ApiClientError::UnexpectedError(content.entity))
                    }
                }
            }
            Err(openapi::Error::Reqwest(e)) => {
                Err(ApiClientError::RequestError(e.to_string()))
            }
            Err(error) => Err(ApiClientError::from(error)),
        }
    }
}
```

**CSI Status Code Mapping** (`controller.rs:1000-1020`):
```rust
.map_err(|error| match error {
    // Storage/resource errors
    ApiClientError::ResourceExhausted(reason) => {
        Status::resource_exhausted(reason)         // CSI: RESOURCE_EXHAUSTED
    }
    ApiClientError::PreconditionFailed(reason) => {
        Status::resource_exhausted(reason)         // CSI: RESOURCE_EXHAUSTED (same mapping)
    }
    
    // Not found errors
    ApiClientError::ResourceNotExists(reason) => {
        Status::not_found(reason)                  // CSI: NOT_FOUND
    }
    
    // Request/validation errors
    ApiClientError::RequestError(reason) => {
        Status::invalid_argument(reason)           // CSI: INVALID_ARGUMENT
    }
    
    // Network/connectivity errors
    ApiClientError::DeserializationError(reason) => {
        Status::unavailable(reason)                // CSI: UNAVAILABLE
    }
    
    // Generic errors
    error => Status::internal(error.to_string()), // CSI: INTERNAL
})
```

### Health Monitoring and Readiness

**Control Plane Connectivity Monitoring** (`controller.rs:1400-1450`):
```rust
async fn probe(
    &self,
    _request: tonic::Request<ProbeRequest>,
) -> Result<tonic::Response<ProbeResponse>, tonic::Status> {
    // Verify control plane connectivity
    match RestApiClient::get_client()
        .health_check()
        .await 
    {
        Ok(_) => {
            debug!("CSI controller health check passed");
            Ok(tonic::Response::new(ProbeResponse {
                ready: Some(true),
            }))
        }
        Err(error) => {
            error!("CSI controller health check failed: {}", error);
            Ok(tonic::Response::new(ProbeResponse {
                ready: Some(false),
            }))
        }
    }
}
```

**Graceful Degradation Strategy**:
```rust
// CSI continues operating with cached data during brief control plane outages
async fn handle_control_plane_outage(&self) -> Result<(), Status> {
    // 1. Use cached volume/snapshot metadata for read operations
    // 2. Queue write operations for retry when connectivity restored
    // 3. Return UNAVAILABLE for operations requiring real-time data
    // 4. Implement exponential backoff for reconnection attempts
}
```

## Developer Critical Notes

### Concurrency Gotchas
- **VolumeOpGuard must be held for entire operation duration** - releasing early allows race conditions
- **No nested locking** - acquiring guards for multiple volumes can deadlock
- **Guard RAII is critical** - guards must not be manually dropped or forgotten

### Filesystem Quiescing Pitfalls
- **Unfreeze failures are catastrophic** - frozen filesystems require manual recovery
- **Raw block volumes silently ignore quiesce** - not an error, documented behavior  
- **Mount tracking is node-local** - controller must query correct node for volume location

### Tracing Best Practices
- **Always instrument async functions** with `#[instrument]` for automatic error capture
- **Update spans dynamically** when UUIDs are discovered during processing
- **Use structured logging** with consistent field names across components

### Error Handling Requirements
- **Idempotency is mandatory** for all operations - CSI requires safe retries
- **Error context must be preserved** through all translation layers
- **Network errors should return UNAVAILABLE** to trigger CSI retry logic

These advanced features form the foundation for enterprise-grade CSI functionality and require careful attention to implementation details for reliable operation.