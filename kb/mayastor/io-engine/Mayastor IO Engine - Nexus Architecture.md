---
title: Mayastor IO Engine - Nexus Architecture
type: note
permalink: mayastor/io-engine/mayastor-io-engine-nexus-architecture
---

# Mayastor IO Engine - Nexus Architecture

## Overview
The Nexus is Mayastor's **volume aggregator** that provides unified access to multiple storage replicas. It implements synchronous mirroring (RAID-1 style) across heterogeneous storage backends, providing high availability, data consistency, and transparent failover capabilities.

**Related Documentation**: See [[Mayastor IO Engine - Nexus Child]] for detailed child management.

## Core Architecture

### Main Nexus Structure (`io-engine/src/bdev/nexus/nexus_bdev.rs:216`)
```rust
pub struct Nexus<'n> {
    name: String,                               // Nexus instance name
    req_size: u64,                             // Requested size in bytes
    children: Vec<NexusChild<'n>>,             // Storage replicas
    nvme_params: NexusNvmeParams,              // NVMe-specific parameters
    nexus_uuid: Uuid,                          // Unique identifier
    bdev: Option<Bdev<Nexus<'n>>>,            // SPDK bdev wrapper
    state: Mutex<NexusState>,                  // Current operation state
    data_ent_offset: u64,                      // Data partition offset
    nexus_target: Option<NexusTarget>,         // Publication target (NVMe-oF)
    io_subsystem: Option<NexusIoSubsystem>,    // I/O handling subsystem
    rebuild_history: Mutex<Vec<HistoryRecord>>, // Rebuild operation history
    shutdown_requested: AtomicCell<bool>,      // Graceful shutdown flag
    last_error: IoCompletionStatus,           // Last child error for propagation
}
```

### Nexus States (`io-engine/src/bdev/nexus/nexus_bdev.rs:297`)
```rust
pub enum NexusState {
    Init,           // Created but no children attached
    Closed,         // Offline
    Open,           // Active and serving I/O
    Reconfiguring,  // Updating internal I/O channels
    ShuttingDown,   // Shutdown in progress
    Shutdown,       // Fully shutdown
}
```

## I/O Channel Architecture

### Per-Core I/O Channels (`io-engine/src/bdev/nexus/nexus_channel.rs:17`)
```rust
pub struct NexusChannel<'n> {
    writers: Vec<Box<dyn BlockDeviceHandle>>,    // All healthy + rebuilding children
    readers: Vec<Box<dyn BlockDeviceHandle>>,    // Only fully synced children
    detached: Vec<Box<dyn BlockDeviceHandle>>,   // Children being removed
    io_logs: Vec<IOLogChannel>,                  // Per-child I/O logging
    previous_reader: UnsafeCell<usize>,          // Round-robin reader index
    fail_fast: u32,                             // Fast failure mode
    io_mode: IoMode,                            // I/O dispatch mode
    frozen_ios: Vec<NexusBio<'n>>,             // Suspended I/Os during reconfig
}
```

**Key Concept**: Each reactor core maintains independent I/O channels for lock-free parallel processing.

## I/O Operations and Data Flow

### Write Operations (Synchronous Mirroring)

#### Write to All Replicas (`io-engine/src/bdev/nexus/nexus_io.rs:553`)
```rust
let result = self.channel().for_each_writer(|h| {
    match self.io_type() {
        IoType::Write => self.submit_write(h),
        IoType::WriteZeros => self.submit_write_zeroes(h),
        IoType::Unmap => self.submit_unmap(h),
        // ... other write types
    }
});
```

**Write Process**:
1. **Broadcast**: Write submitted to **all** healthy and rebuilding children simultaneously
2. **Synchronous completion**: Write completes only when **all** replicas succeed
3. **Fault handling**: Failed replicas are marked faulted and removed from writers
4. **Atomic operation**: Either all replicas succeed or the write fails

#### Write Completion Logic (`io-engine/src/bdev/nexus/nexus_io.rs:251`)
```rust
if self.ctx().failed == 0 {
    self.ok();                    // All replicas succeeded
} else if self.ctx().successful > 0 {
    self.resubmit();             // Some succeeded, retry with healthy children
} else {
    self.fail();                 // All failed, fail the I/O
}
```

### Read Operations (Load Balancing)

#### Reader Selection (`io-engine/src/bdev/nexus/nexus_channel.rs:197`)
```rust
pub(crate) fn select_reader(&self) -> Option<&dyn BlockDeviceHandle> {
    if self.readers.is_empty() {
        None
    } else {
        // Round-robin across healthy children
        let idx = unsafe { 
            let idx = &mut *self.previous_reader.get();
            *idx = (*idx + 1) % self.readers.len();
            *idx
        };
        Some(self.readers[idx].as_ref())
    }
}
```

**Read Process**:
1. **Single replica**: Each read served by exactly one healthy child
2. **Load balancing**: Round-robin distribution across healthy children
3. **Fault tolerance**: Failed reads automatically retry with different children
4. **Performance**: Parallel reads across multiple children for different I/Os

## Child Management and Health Monitoring

### Child Health Determination
- **Healthy children**: `ChildState::Open` + `ChildSyncState::Synced`
  - Eligible for both reads and writes
- **Rebuilding children**: `ChildState::Open` + `ChildSyncState::OutOfSync`
  - Write-only during rebuild process
- **Faulted children**: `ChildState::Faulted`
  - Excluded from all I/O operations

*See [[Mayastor IO Engine - Nexus Child]] for detailed child state management.*

### Dynamic Reconfiguration (`io-engine/src/bdev/nexus/nexus_channel.rs:282`)

#### Channel Reconnection
```rust
pub(crate) fn reconnect_all(&mut self) {
    // Clear existing handles
    self.writers.clear();
    self.readers.clear();
    
    // Reconnect healthy children as both readers and writers
    self.nexus().children_iter()
        .filter(|c| c.is_healthy())
        .for_each(|c| {
            writers.push(w);
            readers.push(r);
        });
    
    // Add rebuilding children as write-only
    self.nexus().children_iter()
        .filter(|c| c.is_rebuilding())
        .for_each(|c| {
            writers.push(hdl);  // Write-only during rebuild
        });
}
```

#### Zero-Downtime Operations
- **Live child addition/removal**: Children can be added/removed while I/O continues
- **Automatic fault detection**: Failed children automatically removed from active sets
- **I/O suspension**: Critical reconfigurations temporarily suspend I/O
- **Immediate recovery**: Faulted children with recoverable faults are automatically retried

## Fault Handling and Recovery

### Write Retry Mechanism (`io-engine/src/bdev/nexus/nexus_io.rs:291`)
```rust
fn resubmit(&mut self) {
    warn!("resubmitting nexus I/O due to a child I/O failure");
    
    ctx.resubmits += 1;        // Track retry attempts
    ctx.successful = 0;        // Reset counters
    ctx.failed = 0;
    
    bio.submit_request();      // Retry with remaining healthy children
}
```

### Fault Propagation
- **Immediate resubmission**: Failed writes retry immediately with healthy children
- **No artificial delays**: No exponential backoff or throttling
- **Child resurrection**: Faulted children periodically reconnected
- **Error context preservation**: Last child error propagated to client

## Storage Backend Integration

### Supported Child Types
The Nexus supports heterogeneous storage backends:

- **NVMe-oF replicas**: `nvmf://host:port/nqn.target`
- **Local NVMe devices**: `nvme://controller` or `nvme://pci_address`
- **Lvol replicas**: `lvol://pool/volume` (with snapshot support)
- **AIO devices**: `aio:///dev/device` or `aio://file.img`
- **IO uring devices**: `uring:///dev/device` 
- **iSCSI targets**: `iscsi://host/target`

### COW and Snapshot Implementation

**COW is NOT implemented by Nexus directly** - instead:

1. **Delegation to children**: Nexus coordinates snapshot operations across all children
2. **Child-specific COW**: Lvol children use SPDK's native COW implementation
3. **Consistency coordination**: All healthy children must support snapshots
4. **Atomic snapshots**: All replicas snapshot simultaneously or operation fails

**Storage Stack for COW-enabled setup**:
```
Nexus (coordinator)
  ↓
Nexus Children (replicas)
  ↓
Lvol (SPDK logical volumes)  ← COW snapshots here
  ↓
LVS (SPDK lvol store)        ← Automatically created
  ↓
Base bdev (nvme, aio, etc.)
  ↓
Physical storage
```

*See [[Mayastor IO Engine - Nexus Child]] for detailed URI schemes and backend types.*

## Rebuild Operations

### Rebuild Process Flow
1. **New child addition**: Child added as `Open` + `OutOfSync`
2. **Write-only mode**: New child participates in writes but not reads
3. **I/O logging**: Healthy children log concurrent writes during rebuild
4. **Data copy**: Background job copies existing data to new child
5. **Log replay**: Concurrent writes are applied to rebuilt child  
6. **Promotion**: Child transitions to `Synced` and becomes read-eligible

### Rebuild Optimization
- **I/O logging**: Only rebuild blocks that changed during rebuild process
- **Parallel rebuild**: Multiple children can rebuild concurrently
- **Throttled rebuild**: Rebuild process yields to application I/O
- **History tracking**: Rebuild operations are logged for diagnostics

## NVMe-oF Integration and Features

### NVMe Parameters (`io-engine/src/bdev/nexus/nexus_bdev.rs:148`)
```rust
pub struct NexusNvmeParams {
    min_cntlid: u16,                // Minimum controller ID
    max_cntlid: u16,                // Maximum controller ID  
    resv_key: u64,                  // Reservation key
    preempt_key: Option<u64>,       // Preemption key
    preempt_policy: NexusNvmePreemption, // Preemption policy
}
```

### NVMe Reservation Support
- **Split-brain prevention**: NVMe reservations prevent concurrent nexus access to children
- **Automatic preemption**: Failed nexus instances can be preempted
- **Persistence through power loss**: Reservations survive storage reboots

### ANA (Asymmetric Namespace Access)
- **Multi-path support**: Multiple nexus instances can serve same namespace
- **Path optimization**: Clients can prefer local paths for better performance

## Performance Characteristics

### Scalability
- **Per-core channels**: Lock-free I/O processing on each reactor core
- **Parallel operations**: Independent I/O pipelines per core
- **Zero-copy**: Direct memory access between children and applications

### Latency Optimization
- **Direct I/O dispatch**: No intermediate queuing or batching
- **Bypass on single child**: Potential optimization for single-replica volumes
- **SPDK integration**: Native SPDK I/O for minimal latency overhead

### Fault Tolerance
- **Immediate failover**: Failed I/Os retry instantly with healthy children
- **No single point of failure**: Any single child can fail without data loss
- **Graceful degradation**: Performance maintained with reduced replica count

## Example Use Cases

### Traditional RAID-1 Replacement
```
Nexus "vol1"
├── Child: nvme://0000:01:00.0/namespace1
└── Child: nvme://0000:02:00.0/namespace1
```

### Distributed Storage Replication  
```
Nexus "distributed-vol"
├── Child: nvmf://node1.cluster:4420/nqn.replica.uuid1
├── Child: nvmf://node2.cluster:4420/nqn.replica.uuid2
└── Child: nvmf://node3.cluster:4420/nqn.replica.uuid3
```

### Hybrid Local/Remote Configuration
```
Nexus "hybrid-vol"
├── Child: nvme://local-ssd (low latency)
└── Child: nvmf://remote-storage:4420/nqn.replica (durability)
```

## Source Code Locations
- **Main nexus implementation**: `io-engine/src/bdev/nexus/nexus_bdev.rs`
- **I/O operations**: `io-engine/src/bdev/nexus/nexus_io.rs`
- **Channel management**: `io-engine/src/bdev/nexus/nexus_channel.rs`
- **Child management**: `io-engine/src/bdev/nexus/nexus_child.rs`
- **Rebuild operations**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs`
- **Snapshot coordination**: `io-engine/src/bdev/nexus/nexus_bdev_snapshot.rs`
- **Module exports**: `io-engine/src/bdev/nexus/mod.rs`