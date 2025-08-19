---
title: Mayastor IO Engine - Nexus Child
type: note
permalink: mayastor/io-engine/mayastor-io-engine-nexus-child
---

# Mayastor IO Engine - Nexus Child

## Overview
A Nexus Child represents a single storage replica within a Nexus volume. Each child corresponds to an individual storage backend (NVMe-oF target, local NVMe device, lvol replica, etc.) and manages its lifecycle, health, synchronization state, and I/O operations.

## Core Architecture

### Child Structure (`io-engine/src/bdev/nexus/nexus_child.rs:263`)
```rust
pub struct NexusChild<'c> {
    parent: String,                               // Parent nexus name
    state: AtomicCell<ChildState>,               // Operational state
    sync_state: AtomicCell<ChildSyncState>,      // Data consistency state
    destroy_state: AtomicCell<ChildDestroyState>, // Destruction lifecycle
    faulted_at: Mutex<Option<DateTime<Utc>>>,    // Fault timestamp
    name: String,                                // Child URI
    device: Option<Box<dyn BlockDevice>>,        // Underlying block device
    device_descriptor: Option<Box<dyn BlockDeviceDescriptor>>,
    io_log: Mutex<Option<IOLog>>,               // I/O logging for rebuild
}
```

## Dual State Management System

### 1. Operational State (`ChildState`)
```rust
pub enum ChildState {
    Init,                    // Being opened/initialized
    ConfigInvalid,          // Incompatible configuration
    Open,                   // Available for I/O operations
    Closed,                 // Offline/disconnected
    Faulted(FaultReason),   // Failed with specific reason
}
```

### 2. Data Consistency State (`ChildSyncState`)
```rust
pub enum ChildSyncState {
    Synced,      // Fully synchronized - can read and write
    OutOfSync,   // Needs rebuild - write-only during rebuild
}
```

**Key Insight**: These states are independent. A child can be `Open` but `OutOfSync` (participating in writes during rebuild but not eligible for reads).

## Health and Eligibility Determination

### Health Check (`io-engine/src/bdev/nexus/nexus_child.rs:497`)
```rust
pub fn is_healthy(&self) -> bool {
    self.state() == ChildState::Open && self.sync_state() == ChildSyncState::Synced
}
```

### Rebuild Detection (`io-engine/src/bdev/nexus/nexus_child.rs:503`)
```rust
pub(crate) fn is_rebuilding(&self) -> bool {
    self.rebuild_job().is_some() && self.is_opened_unsync()
}
```

### I/O Eligibility
- **Read Operations**: Only `is_healthy()` children (Open + Synced)
- **Write Operations**: `is_healthy()` + `is_rebuilding()` children (includes OutOfSync during rebuild)

*Source: `io-engine/src/bdev/nexus/nexus_channel.rs:322-340`*

## Fault Handling and Recovery

### Fault Reasons (`io-engine/src/bdev/nexus/nexus_child.rs:113`)
```rust
pub enum FaultReason {
    Unknown,              // Unspecified failure
    CantOpen,            // Cannot open device (non-recoverable)
    NoSpace,             // Out of space (recoverable)
    TimedOut,            // I/O timeout (recoverable)
    IoError,             // I/O error (recoverable)
    RebuildFailed,       // Rebuild process failed (recoverable)
    AdminCommandFailed,  // Admin command failed (recoverable)
    Offline,             // Administratively offline (recoverable)
    OfflinePermanent,    // Permanently offline (non-recoverable)
}
```

### Fault Recovery (`io-engine/src/bdev/nexus/nexus_child.rs:147`)
```rust
pub fn is_recoverable(&self) -> bool {
    matches!(self,
        Self::NoSpace | Self::TimedOut | Self::IoError | 
        Self::Offline | Self::AdminCommandFailed | Self::RebuildFailed
    )
}
```

**Recovery Process**: Nexus periodically attempts to reconnect faulted children with recoverable fault reasons through dynamic reconfiguration.

## URI-Based Child Identification

### Supported URI Schemes
Children are identified by URIs that specify the storage backend:

- **NVMe-oF targets**: `nvmf://host:port/nqn.target.name`
- **Lvol replicas**: `lvol://pool_name/volume_name?size=10GiB`
- **Local NVMe**: `nvme://pci_address` or `nvme://controller_name`
- **AIO devices**: `aio:///dev/device_path`
- **iSCSI targets**: `iscsi://host/target_name`

*Example usage in `io-engine/src/bdev/lvs.rs:6-18`*

## NVMe Reservations for Split-Brain Prevention

### Reservation Operations (`io-engine/src/bdev/nexus/nexus_child.rs:507-574`)

#### Registration
```rust
async fn resv_register(&self, hdl: &dyn BlockDeviceHandle, new_key: u64) -> Result<(), CoreError>
```

#### Release
```rust  
async fn resv_release(&self, hdl: &dyn BlockDeviceHandle, current_key: u64, 
                     resv_type: NvmeReservation, release_action: u8) -> Result<(), CoreError>
```

#### Status Check
```rust
async fn resv_holder(&self, hdl: &dyn BlockDeviceHandle) -> Result<Option<(u8, u64, [u8; 16])>, ChildError>
```

### Reservation Types
- **ExclusiveAccessAllRegs**: Exclusive access across all registered controllers
- **WriteExclusiveAllRegs**: Write exclusive access across all registered controllers

### Features
- **Split-brain prevention**: Only one Nexus can hold write reservation per child
- **Automatic preemption**: Can steal reservations from failed Nexus instances
- **Persistence Through Power Loss (PTPL)**: Reservations survive storage device reboots

*Source: `io-engine/src/bdev/nexus/nexus_bdev.rs:107-130`*

## I/O Logging and Rebuild Optimization

### I/O Log Structure (`io-engine/src/bdev/nexus/nexus_child.rs:295`)
```rust
io_log: Mutex<Option<IOLog>>,  // Tracks writes during rebuild
```

### Purpose
- **Efficient rebuild**: Only rebuild blocks that changed during rebuild process
- **Write tracking**: Logs all writes to healthy children while rebuilding child is out-of-sync
- **Channel-level optimization**: Each reactor core maintains separate I/O logs for performance

### Operation
1. Child starts rebuild → I/O logging begins on healthy children
2. Concurrent writes are logged while rebuild copies existing data
3. After bulk copy complete → replay logged writes to rebuilt child
4. Rebuild complete → child transitions to `Synced` state

*Referenced in `io-engine/src/bdev/nexus/nexus_io.rs:607-627`*

## Client API State Abstraction

### External State Representation (`io-engine/src/bdev/nexus/nexus_child.rs:418`)
```rust
pub fn state_client(&self) -> ChildStateClient {
    if self.is_opened_unsync() {
        return ChildStateClient::OutOfSync;  // Special external state
    }
    
    match self.state() {
        ChildState::Faulted(r) => {
            if self.is_destroying() {
                ChildStateClient::Faulting(r)    // Transitional state
            } else {
                ChildStateClient::Faulted(r)
            }
        }
        // ... other state mappings
    }
}
```

**Purpose**: Provides simplified, user-friendly state representation that hides internal implementation complexity.

## Child Lifecycle Management

### Creation Process
1. **URI parsing**: Child URI is parsed to determine backend type
2. **Device opening**: Underlying BlockDevice is opened with appropriate parameters
3. **State initialization**: Child starts in `Init` state
4. **Health validation**: Configuration compatibility is verified
5. **State transition**: `Init` → `Open` (healthy) or `ConfigInvalid`/`Faulted`

### Rebuild Integration
1. **Addition**: New child added as `Open` + `OutOfSync`
2. **Write-only mode**: Child participates in writes but not reads
3. **Rebuild job**: Background rebuild copies data from healthy children
4. **I/O log replay**: Concurrent writes are applied to rebuilt child
5. **Promotion**: `OutOfSync` → `Synced`, child becomes read-eligible

### Destruction Process (`io-engine/src/bdev/nexus/nexus_child.rs:246`)
```rust
pub(crate) enum ChildDestroyState {
    None,        // Normal operation
    Destroying,  // Safe cleanup in progress
}
```

**Safe destruction ensures**:
- In-flight I/Os complete before device disconnection
- NVMe reservations are properly released
- Device handles are safely closed
- I/O logs are cleaned up

## Error Handling and Diagnostics

### Fault Timestamp Tracking
```rust
faulted_at: Mutex<Option<DateTime<Utc>>>,  // When child was faulted
```

### Debug Representation (`io-engine/src/bdev/nexus/nexus_child.rs:301`)
```rust
write!(f, "Child '{name} @ {nexus}' [{state}{destroy_state} {sync_state}{rebuild}{io_log}]")
```

**Example**: `Child 'nvmf://10.0.1.5/nqn.replica.uuid @ nexus-vol1' [Open OutOfSync R L]`
- `R` = Rebuilding
- `L` = Has I/O log

## Source Code Locations
- **Main implementation**: `io-engine/src/bdev/nexus/nexus_child.rs`
- **State definitions**: `io-engine/src/bdev/nexus/nexus_child.rs:162-249`
- **I/O integration**: `io-engine/src/bdev/nexus/nexus_channel.rs:319-355`
- **Rebuild coordination**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs`
- **NVMe reservations**: `io-engine/src/bdev/nexus/nexus_child.rs:507-589`