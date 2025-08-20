---
title: Mayastor Path Detection and Monitoring
type: note
permalink: mayastor/ha/mayastor-path-detection-and-monitoring
---

# Mayastor Path Detection and Monitoring

## Overview
Mayastor implements client-side NVMe-oF path monitoring to detect connection failures between client nodes and Nexus instances, enabling rapid HA switchover without waiting for full node failure detection.

## Architecture

### Monitoring Target
```
Client Node → NVMe-oF Connection → Nexus (on io-engine node) → Storage
              ↑
         This connection is monitored
```

The system monitors **client-side NVMe-oF connections**, not the storage backend paths themselves.

## Node Agent Implementation

### Detector Core (`controller/control-plane/agents/src/bin/ha/node/detector.rs`)
```rust
pub struct PathDetector {
    node_id: String,                    // Client node identifier
    monitored_paths: HashMap<VolumeId, PathState>,  // Per-volume path tracking
    failure_threshold: Duration,        // Time before marking SUSPECTED
    confirmed_threshold: Duration,      // Time before marking FAILED
}
```

### Detection State Machine
```rust
pub enum PathState {
    Live,        // Connection healthy
    Suspected,   // Potentially failing (first "connecting" detected)
    Failed,      // Confirmed failure (second consecutive "connecting")
}
```

### Detection Logic (`controller/control-plane/agents/src/bin/ha/node/detector.rs`)
```rust
async fn check_nvme_path_state(&self, volume_uuid: &VolumeId) -> PathCheckResult {
    // Read /sys/class/nvme/nvmeX/state for NVMe controller
    let controller_state = read_nvme_controller_state(volume_uuid).await?;
    
    match controller_state.as_str() {
        "live" => PathCheckResult::Healthy,
        "connecting" => {
            if self.was_previously_connecting(volume_uuid) {
                PathCheckResult::Failed    // Second consecutive "connecting" = failure
            } else {
                PathCheckResult::Suspected  // First "connecting" = suspected
            }
        }
        _ => PathCheckResult::Unknown,
    }
}
```

## Detection Process

### Monitoring Loop
```rust
async fn monitor_paths(&mut self) {
    loop {
        for (volume_uuid, current_state) in &mut self.monitored_paths {
            match self.check_nvme_path_state(volume_uuid).await {
                PathCheckResult::Healthy => {
                    *current_state = PathState::Live;
                }
                PathCheckResult::Suspected => {
                    if matches!(current_state, PathState::Live) {
                        *current_state = PathState::Suspected;
                        self.schedule_recheck(volume_uuid).await;
                    }
                }
                PathCheckResult::Failed => {
                    if matches!(current_state, PathState::Suspected) {
                        *current_state = PathState::Failed;
                        self.report_path_failure(volume_uuid).await;
                    }
                }
            }
        }
        
        tokio::time::sleep(self.check_interval).await;  // Default: 5 seconds
    }
}
```

### Failure Reporting
```rust
async fn report_path_failure(&self, volume_uuid: &VolumeId) {
    let failure_report = PathFailureReport {
        client_node: self.node_id.clone(),
        volume_uuid: volume_uuid.clone(),
        nexus_endpoint: self.get_nexus_endpoint(volume_uuid),
        failure_type: PathFailureType::NvmeConnecting,
        detected_at: Utc::now(),
    };
    
    // Send to HA Cluster Agent for switchover initiation
    self.ha_cluster_client
        .report_path_failure(failure_report)
        .await?;
}
```

## Integration with HA Switchover

### Failure Report Structure
```rust
pub struct PathFailureReport {
    pub client_node: String,        // Which client detected the failure
    pub volume_uuid: VolumeId,      // Affected volume
    pub nexus_endpoint: String,     // Failed nexus NVMe-oF endpoint
    pub failure_type: PathFailureType,
    pub detected_at: DateTime<Utc>,
}

pub enum PathFailureType {
    NvmeConnecting,    // NVMe controller stuck in "connecting" state
    NvmeDisconnected,  // NVMe controller completely disconnected
    IoTimeout,         // I/O operations timing out
}
```

### HA Cluster Agent Integration
The HA Cluster Agent receives path failure reports and initiates the 5-stage switchover process:

```rust
// In controller/control-plane/agents/src/bin/ha/cluster/main.rs
async fn handle_path_failure_report(&mut self, report: PathFailureReport) -> Result<(), Error> {
    // Create switchover request from path failure
    let switchover_request = SwitchoverRequest {
        volume_uuid: report.volume_uuid,
        failed_node: self.resolve_node_from_endpoint(&report.nexus_endpoint),
        requesting_client: report.client_node,
        trigger_reason: SwitchoverReason::PathFailure(report.failure_type),
    };
    
    // Begin persistent switchover process
    self.execute_switchover(switchover_request).await
}
```

## NVMe Controller State Access

### Sysfs Interface
```rust
async fn read_nvme_controller_state(volume_uuid: &VolumeId) -> Result<String, DetectorError> {
    // Map volume UUID to NVMe controller via subsystem NQN
    let nqn = format!("nqn.2019-05.io.openebs:{}", volume_uuid);
    let controller_path = find_controller_by_nqn(&nqn)?;
    
    // Read controller state from /sys/class/nvme/nvmeX/state
    let state_path = format!("/sys/class/nvme/{}/state", controller_path);
    fs::read_to_string(state_path).await?.trim().to_string()
}
```

### NVMe Subsystem NQN Mapping
- **Volume NQN**: `nqn.2019-05.io.openebs:${volume_uuid}`
- **Controller Path**: `/sys/class/nvme/nvmeX/` (where X maps to the NQN)
- **State File**: `/sys/class/nvme/nvmeX/state` contains current connection state

## Configuration

### Node Agent Configuration
```rust
pub struct NodeAgentConfig {
    pub path_check_interval: Duration,      // Default: 5 seconds
    pub failure_threshold: Duration,        // Default: 10 seconds  
    pub confirmed_threshold: Duration,      // Default: 15 seconds
    pub max_concurrent_checks: usize,       // Default: 100
}
```

### Environment Variables
- `MAYASTOR_NODE_AGENT_PATH_CHECK_INTERVAL`: Override check frequency
- `MAYASTOR_NODE_AGENT_FAILURE_THRESHOLD`: Time before suspected failure
- `MAYASTOR_NODE_AGENT_CONFIRMED_THRESHOLD`: Time before confirmed failure

## Error Handling

### Detection Failures
```rust
pub enum DetectorError {
    NvmeControllerNotFound(VolumeId),     // Can't find NVMe controller for volume
    SysfsAccessError(String),             // Can't read sysfs files
    InvalidControllerState(String),       // Unexpected state value
    CommunicationError(String),           // Can't reach HA cluster agent
}
```

### Recovery Mechanisms
- **Retry logic**: Failed checks are retried with exponential backoff
- **State validation**: Multiple confirmations required before reporting failures  
- **Graceful degradation**: Communication failures don't affect local monitoring

## Design Rationale

### Why Client-Side Monitoring
- **Fast detection**: Client immediately sees NVMe connection issues
- **Distributed**: Multiple clients can detect failures independently
- **Granular**: Per-volume path monitoring vs. coarse node-level detection

### NVMe "connecting" State Detection
- **Early warning**: "connecting" indicates potential failure before complete disconnection
- **False positive reduction**: Requires two consecutive "connecting" states
- **Integration**: Leverages existing NVMe multipath infrastructure

## Source Code Locations
- **Core detector**: `controller/control-plane/agents/src/bin/ha/node/detector.rs`
- **Node agent main**: `controller/control-plane/agents/src/bin/ha/node/main.rs`  
- **HA cluster integration**: `controller/control-plane/agents/src/bin/ha/cluster/main.rs`
- **Failure reporting**: `controller/control-plane/agents/src/bin/ha/node/reporter.rs`