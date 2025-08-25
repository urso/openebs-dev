---
title: Mayastor IO Engine - Rebuild Architecture and Sparse Block Detection
type: note
permalink: mayastor/io-engine/mayastor-io-engine-rebuild-architecture-and-sparse-block-detection
---

# Mayastor IO Engine - Rebuild Architecture and Sparse Block Detection

## Overview

Mayastor implements **differential rebuild operations** that automatically detect and copy only allocated blocks during replica reconstruction, avoiding unnecessary copying of sparse/unallocated regions. This is achieved through SPDK's native thin-provisioning capabilities and NVMe error handling, rather than maintaining separate allocation bitmaps.

**Key Innovation**: Instead of pre-computing allocation bitmaps, Mayastor uses **runtime sparse block detection** via special read flags that cause storage layers to return error codes for unallocated regions.

**Related Documentation**: 
- [[Mayastor IO Engine - Nexus Architecture]] for nexus rebuild coordination
- [[Mayastor IO Engine - Logical Volume Store]] for LVOL allocation behavior

## Core Architecture

### Rebuild Types

Mayastor supports two distinct rebuild modes based on allocation detection capability:

#### 1. **Full Rebuild** (Default Fallback)
**Implementation**: `io-engine/src/rebuild/bdev_rebuild.rs:79-86`
```rust
None => {
    let backend = BdevRebuildJobBackend {
        task_pool,
        notify_fn,
        copier: FullRebuild::new(descriptor),  // ← Copies entire device range
    };
}
```

#### 2. **Partial Rebuild** (Sparse-Aware)
**Implementation**: `io-engine/src/rebuild/bdev_rebuild.rs:70-78`
```rust
Some(map) => {
    descriptor.validate_map(&map)?;
    let backend = BdevRebuildJobBackend {
        task_pool,
        notify_fn,
        copier: PartialRebuild::new(map, descriptor),  // ← Uses allocation bitmap
    };
}
```

### Sparse Block Detection Mechanism

#### Runtime Allocation Detection
**Implementation**: `io-engine/src/rebuild/rebuild_task.rs:61-67`
```rust
if !desc.read_src_segment(offset_blk, iovs, desc.options.read_opts).await? {
    // Segment is not allocated in the source, skip the write.
    return Ok(false);  // ← No copy operation performed
}
desc.write_dst_segment(offset_blk, iovs).await?;  // ← Only if data exists
```

#### Error-Based Allocation Detection
**Implementation**: `io-engine/src/rebuild/rebuild_descriptor.rs:203-229`
```rust
/// Reads a rebuild segment at the given offset from the source replica.
/// In the case the segment is not allocated on the source, returns false,
/// and true otherwise.
pub(super) async fn read_src_segment(
    &self,
    offset_blk: u64,
    iovs: &mut [IoVec],
    opts: ReadOptions,
) -> Result<bool, RebuildError> {
    match self.src_io_handle().readv_blocks_async(
        iovs, offset_blk, self.get_segment_size_blks(offset_blk), opts
    ).await {
        // Read is okay, data has to be copied to the destination.
        Ok(_) => Ok(true),

        // Read from an unallocated block occurred, no need to copy it.
        Err(CoreError::ReadFailed {
            status: IoCompletionStatus::NvmeError(NvmeStatus::UNWRITTEN_BLOCK),
            ..
        }) => Ok(false),  // ← Skip copying unallocated blocks

        // Read error.
        Err(err) => Err(RebuildError::ReadIoFailed { /* ... */ })
    }
}
```

## Read Options and SPDK Flag Integration

### Special Read Behavior During Rebuild

**Normal block device behavior**: Reading unallocated blocks returns zeros
**Mayastor rebuild behavior**: Reading unallocated blocks returns errors

#### Nexus Rebuild Configuration
**Implementation**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs:113`
```rust
let opts = RebuildJobOptions {
    verify_mode,
    read_opts: crate::core::ReadOptions::UnwrittenFail,  // ← KEY: Enable error-on-unallocated
};
```

#### Snapshot Rebuild Configuration  
**Implementation**: `io-engine/src/rebuild/snapshot_rebuild.rs:280`
```rust
pub fn builder() -> SnapshotRebuildJobBuilder {
    SnapshotRebuildJobBuilder::builder().with_option(
        RebuildJobOptions::default().with_read_opts(ReadOptions::CurrentUnwrittenFail),
    )
}
```

### Read Options Definitions
**Implementation**: `io-engine/src/core/block_device.rs:130-140`
```rust
#[derive(Default, Debug, Copy, Clone)]
pub enum ReadOptions {
    /// Normal read operation.
    #[default]
    None,
    /// Fail when reading an unwritten block of a thin-provisioned device.
    UnwrittenFail,
    /// Fail when reading an unwritten block of a thin-provisioned device.
    CurrentUnwrittenFail,
}
```

### SPDK Flag Translation
**Implementation**: `io-engine/src/bdev/device.rs:443-446`
```rust
impl From<ReadOptions> for u32 {
    fn from(opts: ReadOptions) -> Self {
        match opts {
            ReadOptions::None => 0,
            ReadOptions::UnwrittenFail => SPDK_NVME_IO_FLAGS_UNWRITTEN_READ_FAIL,
            ReadOptions::CurrentUnwrittenFail => SPDK_NVME_IO_FLAG_CURRENT_UNWRITTEN_READ_FAIL,
        }
    }
}
```

## NVMe Error Code Handling

### UNWRITTEN_BLOCK Status Code
**Implementation**: `spdk-rs/src/nvme.rs:310-312`
```rust
impl NvmeStatus {
    /// Shorthand for SPDK_NVME_SC_DEALLOCATED_OR_UNWRITTEN_BLOCK.
    pub const UNWRITTEN_BLOCK: Self = Self::Media(SPDK_NVME_SC_DEALLOCATED_OR_UNWRITTEN_BLOCK);
}
```

### Error Handling in Block Device Handles
**Implementation**: `io-engine/src/core/handle.rs:185-190`
```rust
match r.await.expect("Failed awaiting read IO") {
    NvmeStatus::SUCCESS => Ok(buffer.len()),
    NvmeStatus::UNWRITTEN_BLOCK => Err(CoreError::ReadingUnallocatedBlock {
        offset,
        len: buffer.len(),
    }),
    status => Err(CoreError::ReadFailed {
        status: IoCompletionStatus::NvmeError(status),
        // ...
    })
}
```

**Implementation**: `io-engine/src/bdev/nvmx/handle.rs:225-230`
```rust
NvmeStatus::UNWRITTEN_BLOCK => Err(CoreError::ReadingUnallocatedBlock {
    offset,
    len: buffer.len(),
}),
```

## Device Type Support Matrix

### Devices Supporting Sparse Detection

#### **Thin-Provisioned LVOLs** ✅
- **Backend**: SPDK blob store with cluster allocation tracking
- **Mechanism**: Blob layer reports unallocated clusters as `UNWRITTEN_BLOCK`
- **Granularity**: SPDK cluster size (typically 1-4MB)
- **Reliability**: Always accurate - native SPDK support

#### **NVMe Devices with Deallocate Support** ✅  
- **Backend**: Modern NVMe SSDs with deallocate/discard support
- **Mechanism**: Device firmware reports deallocated LBA ranges
- **Granularity**: Device-specific (varies by vendor/model)
- **Reliability**: Device-dependent implementation

### Devices NOT Supporting Sparse Detection

#### **Thick-Provisioned LVOLs** ❌
- All clusters pre-allocated at creation time
- No unallocated regions to detect
- Falls back to full rebuild

#### **AIO/File-Based Devices** ❌
- File systems typically zero-fill on read
- No native sparse block error reporting
- Falls back to full rebuild

#### **Legacy Block Devices** ❌
- No deallocate support or sparse awareness
- Always return zeros for any read operation
- Falls back to full rebuild

## Rebuild Process Flow

### 1. **Rebuild Initiation** 
**Entry Point**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs:70-99`
```rust
pub async fn start_rebuild(&self, child_uri: &str) -> Result<Receiver<RebuildState>, Error> {
    // Find a healthy child to rebuild from.
    let Some(src_child_uri) = self.find_src_replica(child_uri) else {
        return Err(Error::NoRebuildSource { name: name.clone() });
    };
    
    // Validate destination child is in correct state
    let dst_child_uri = match self.lookup_child(child_uri) {
        Some(c) if c.is_opened_unsync() => { /* ... */ }
        // ...
    }
}
```

### 2. **Job Creation with Sparse Detection**
**Implementation**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs:101-120`
```rust
let opts = RebuildJobOptions {
    verify_mode,
    read_opts: crate::core::ReadOptions::UnwrittenFail,  // ← Enable sparse detection
};

NexusRebuildJob::new_starter(
    &self.name,
    src_child_uri,
    dst_child_uri,
    std::ops::Range::<u64> {
        start: self.data_ent_offset,
        end: self.num_blocks() + self.data_ent_offset,
    },
    opts,
)
```

### 3. **Segment-by-Segment Processing**
**Implementation**: `io-engine/src/rebuild/rebuild_task.rs:52-75`
```rust
/// Copies one segment worth of data from source into destination.
/// Returns true if write transfer took place, false otherwise.
pub(super) async fn copy_one(
    &mut self,
    offset_blk: u64,
    desc: &RebuildDescriptor,
) -> Result<bool, RebuildError> {
    let iov = desc.adjusted_iov(&self.buffer, offset_blk);
    let iovs = &mut [iov];

    if !desc.read_src_segment(offset_blk, iovs, desc.options.read_opts).await? {
        // Segment is not allocated in the source, skip the write.
        return Ok(false);  // ← No I/O to destination
    }
    desc.write_dst_segment(offset_blk, iovs).await?;  // ← Only allocated segments copied

    if !matches!(desc.options.verify_mode, RebuildVerifyMode::None) {
        desc.verify_segment(offset_blk, iovs).await?;
    }

    Ok(true)
}
```

### 4. **Concurrent Operation Handling**
During rebuild, the nexus maintains **I/O logging** to handle concurrent writes:

**Implementation**: `io-engine/src/bdev/nexus/nexus_io_log.rs:89-95`
```rust
/// Logs the given operation, marking the corresponding segment as modified
pub(crate) fn log_io(&self, offset: u64, num_blks: u64) {
    if let Some(ref segments) = unsafe { &mut *self.segments.get() } {
        segments.set(offset, num_blks, true);  // ← Track concurrent writes
    }
}
```

## Performance Characteristics

### Efficiency Gains

#### **Space Efficiency**
- **Sparse volumes**: Only allocated blocks transferred over network
- **Snapshot-based rebuilds**: Minimal data movement for COW snapshots
- **Network bandwidth**: Reduced by ratio of allocated vs. total capacity

#### **Time Efficiency**  
- **I/O reduction**: Skip unallocated segments entirely
- **Parallel processing**: 16 concurrent copy tasks per rebuild job
- **Resumable operations**: Checkpoint-based restart capability

### Segment Processing Constants
**Implementation**: `io-engine/src/rebuild/mod.rs:30-34`
```rust
/// Number of concurrent copy tasks per rebuild job
const SEGMENT_TASKS: usize = 16;

/// Size of each segment used by the copy task
pub(crate) const SEGMENT_SIZE: u64 = spdk_rs::libspdk::SPDK_BDEV_LARGE_BUF_MAX_SIZE as u64;
```

## Integration with Nexus Child Management

### Child State During Rebuild
From [[Mayastor IO Engine - Nexus Architecture]]:

1. **New child addition**: Child added as `Open` + `OutOfSync`
2. **Write-only mode**: New child participates in writes but not reads
3. **Data copy**: Background job copies existing allocated data to new child
4. **Log replay**: Concurrent writes applied to rebuilt child
5. **Promotion**: Child transitions to `Synced` and becomes read-eligible

### Rebuild Job Lifecycle
**Implementation**: `io-engine/src/rebuild/rebuild_job.rs:76-89`
```rust
#[derive(Debug)]
pub struct RebuildJob {
    /// Source URI of the healthy child to rebuild from.
    src_uri: String,
    /// Target URI of the out of sync child in need of a rebuild.
    pub(crate) dst_uri: String,
    /// Frontend to backend channel.
    comms: RebuildFBendChan,
    /// Current state of the rebuild job.
    states: Arc<parking_lot::RwLock<RebuildStates>>,
    /// Channel used to Notify rebuild updates when the state changes.
    notify_chan: crossbeam::channel::Receiver<RebuildState>,
    /// Channel used to Notify when rebuild completes.
    complete_chan: Weak<parking_lot::Mutex<Vec<oneshot::Sender<RebuildState>>>>,
}
```

## SegmentMap Implementation

### Bitmap Structure
**Implementation**: `io-engine/src/core/segment_map.rs:8-20`
```rust
#[derive(Clone)]
pub struct SegmentMap<B: BitBlock = u32> {
    /// Bitmap of rebuild segments of a device. Zeros indicate clean segments,
    /// ones mark dirty ones.
    segments: BitVec<B>,
    /// Device size in segments.
    num_segments: u64,
    /// Device size in blocks.
    num_blocks: u64,
    /// Size of block in bytes.
    block_len: u64,
    /// Segment size in bytes.
    segment_size: u64,
}
```

### Bitmap Operations
**Implementation**: `io-engine/src/core/segment_map.rs:56-89`
```rust
/// Sets a segment bit corresponding to the given logical block, to the
/// given value.
pub fn set(&mut self, lbn: u64, lbn_cnt: u64, value: bool) {
    let start_seg = self.lbn_to_seg(lbn);
    let end_seg = self.lbn_to_seg(lbn + lbn_cnt - 1);
    for i in start_seg..=end_seg {
        self.segments.set(i, value);  // ← Mark segments as allocated/dirty
    }
}

/// Counts the total number of dirty blocks.
pub fn count_dirty_blks(&self) -> u64 {
    self.count_ones() * self.segment_size / self.block_len
}
```

### Usage in Rebuild Jobs
**Implementation**: `io-engine/src/rebuild/bdev_rebuild.rs:35-62`
```rust
#[derive(Default)]
pub struct BdevRebuildJobBuilder {
    range: Option<Range<u64>>,
    options: RebuildJobOptions,
    notify_fn: Option<fn(&str, &str) -> ()>,
    rebuild_map: Option<SegmentMap>,  // ← Optional allocation bitmap
}

impl BdevRebuildJobBuilder {
    /// Specify a rebuild map, turning it into a partial rebuild.
    pub fn with_bitmap(mut self, rebuild_map: SegmentMap) -> Self {
        self.rebuild_map = Some(rebuild_map);
        self
    }
}
```

## Error Handling and Device Compatibility

### NVMe Error Code Integration
**Implementation**: `spdk-rs/src/nvme.rs:310-312`
```rust
/// Shorthand for SPDK_NVME_SC_DEALLOCATED_OR_UNWRITTEN_BLOCK.
pub const UNWRITTEN_BLOCK: Self = Self::Media(SPDK_NVME_SC_DEALLOCATED_OR_UNWRITTEN_BLOCK);
```

This maps to the **NVMe 1.4+ specification** error code `02h/0Ah` - "Deallocated or Unwritten Logical Block".

### Graceful Fallback for Incompatible Devices
For devices that don't support sparse detection:
1. **`UnwrittenFail` flag set** during rebuild
2. **Device returns zeros** instead of error codes  
3. **Rebuild proceeds** but copies all segments (full rebuild)
4. **No failures** - graceful degradation to full copy

## Implementation Patterns

### Trait-Based Device Abstraction
**Implementation**: `io-engine/src/core/block_device.rs:145-149`
```rust
#[async_trait(?Send)]
pub trait BlockDeviceHandle {
    /// TODO
    fn get_device(&self) -> &dyn BlockDevice;
    
    async fn readv_blocks_async(
        &self,
        iovs: &mut [IoVec],
        offset_blk: u64,
        num_blks: u64,
        opts: ReadOptions,  // ← Options include UnwrittenFail behavior
    ) -> Result<usize, CoreError>;
}
```

### Device-Specific Implementations
Different device types implement `BlockDeviceHandle` with varying sparse detection capabilities:

- **LVOL handles**: `io-engine/src/lvs/lvs_lvol.rs` (blob allocation aware)
- **NVMe handles**: `io-engine/src/bdev/nvmx/handle.rs` (device deallocate aware)
- **AIO handles**: `io-engine/src/bdev/aio.rs` (no sparse detection)

## Advantages Over Traditional Bitmap Systems

### **1. Always Accurate**
- **No stale bitmap issues** - allocation detected at read time
- **Handles concurrent modifications** during rebuild
- **Device-native accuracy** - leverages storage layer knowledge

### **2. No Pre-Scanning Required**
- **Immediate rebuild start** - no bitmap computation phase
- **Reduced metadata overhead** - no persistent bitmap storage
- **Simpler state management** - no bitmap synchronization

### **3. Universal Backend Support**
- **Works with any storage backend** that supports sparse detection
- **Automatic fallback** to full rebuild for incompatible devices
- **Future-proof** for new storage technologies

### **4. Network Efficiency**
- **Remote rebuilds** automatically skip sparse regions
- **Bandwidth optimization** for distributed storage scenarios
- **Faster recovery times** for mostly-empty volumes

## Limitations and Trade-offs

### **Device Dependency**
- **Requires modern storage** with sparse block reporting
- **Inconsistent support** across different device types/vendors
- **Performance varies** by device sparse detection efficiency

### **Read Amplification**
- **Every segment read twice** - once for detection, once for verification (if enabled)
- **Additional I/O overhead** compared to pre-computed bitmaps
- **May impact source replica performance** during rebuild

### **Error Handling Complexity**
- **Must distinguish** between allocation errors vs. real I/O failures
- **Device-specific quirks** in error reporting behavior
- **Fallback logic** adds code complexity

## Future Enhancements

### **Bitmap Support Implementation**
The protocol includes provisions for explicit bitmap support (currently disabled):

**Implementation**: `io-engine/src/grpc/v1/snapshot_rebuild.rs:43-44`
```rust
let None = request.bitmap else {
    return Err(tonic::Status::invalid_argument("BitMap not supported"));
};
```

**Potential improvement**: Implement bitmap extraction from SPDK blob metadata for even faster rebuild initiation.

### **Performance Optimizations**
- **Adaptive segment sizing** based on device sparse detection performance
- **Concurrent detection and copy** to reduce read amplification
- **Predictive sparse detection** using historical allocation patterns

## Related Source Code Locations

- **Main rebuild coordination**: `io-engine/src/bdev/nexus/nexus_bdev_rebuild.rs`
- **Rebuild task implementation**: `io-engine/src/rebuild/rebuild_task.rs`
- **Segment map structure**: `io-engine/src/core/segment_map.rs`  
- **Block device abstraction**: `io-engine/src/core/block_device.rs`
- **NVMe error handling**: `spdk-rs/src/nvme.rs`
- **SPDK flag integration**: `io-engine/src/bdev/device.rs`
- **Snapshot rebuild service**: `io-engine/src/grpc/v1/snapshot_rebuild.rs`