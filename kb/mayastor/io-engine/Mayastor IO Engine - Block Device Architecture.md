---
title: Mayastor IO Engine - Block Device Architecture
type: note
permalink: mayastor/io-engine/mayastor-io-engine-block-device-architecture
---

# Mayastor IO Engine - Block Device Architecture

## Overview
The Mayastor Block Device Layer provides a unified abstraction over SPDK's bdev system through a three-layer trait architecture, URI-based device factories, and comprehensive infrastructure for device management, monitoring, and fault injection.

## Three-Layer Trait Architecture

### Core Abstraction (`io-engine/src/core/block_device.rs`)

Mayastor implements a **layered trait system** that provides Rust-safe abstractions over SPDK's C APIs:

**1. BlockDevice Trait** - Device metadata and capabilities (`lines 53-92`):
```rust
#[async_trait(?Send)]
pub trait BlockDevice {
    fn size_in_bytes(&self) -> u64;
    fn block_len(&self) -> u64;
    fn uuid(&self) -> Uuid;
    fn product_name(&self) -> String;
    fn driver_name(&self) -> String;
    fn io_type_supported(&self, io_type: IoType) -> bool;
    async fn io_stats(&self) -> Result<BlockDeviceIoStats, CoreError>;
    fn open(&self, read_write: bool) -> Result<Box<dyn BlockDeviceDescriptor>, CoreError>;
}
```

**2. BlockDeviceDescriptor Trait** - Opened device operations (`lines 97-115`):
```rust
#[async_trait(?Send)]  
pub trait BlockDeviceDescriptor {
    fn get_device(&self) -> Box<dyn BlockDevice>;
    fn device_name(&self) -> String;
    fn into_handle(self: Box<Self>) -> Result<Box<dyn BlockDeviceHandle>, CoreError>;
    fn get_io_handle(&self) -> Result<Box<dyn BlockDeviceHandle>, CoreError>;
}
```

**3. BlockDeviceHandle Trait** - I/O operations (`lines 145+`):
```rust
#[async_trait(?Send)]
pub trait BlockDeviceHandle {
    fn get_device(&self) -> &dyn BlockDevice;
    fn dma_malloc(&self, size: u64) -> Result<DmaBuf, DmaError>;
    
    // Callback-based I/O (core operations)
    fn readv_blocks(&self, iovs: &mut [IoVec], offset_blocks: u64, num_blocks: u64,
                   opts: ReadOptions, cb: IoCompletionCallback, cb_arg: IoCompletionCallbackArg) 
                   -> Result<(), CoreError>;
    
    // Async wrappers
    async fn readv_blocks_async(&self, iovs: &mut [IoVec], offset_blocks: u64,
                               num_blocks: u64, opts: ReadOptions) -> Result<(), CoreError>;
}
```

### SPDK Integration Pattern

**Trait Mapping to SPDK Types:**
- `BlockDevice` trait → `spdk_rs::Bdev<T>` → SPDK `spdk_bdev`
- `BlockDeviceDescriptor` trait → `spdk_rs::BdevDesc<T>` → SPDK `spdk_bdev_desc`  
- `BlockDeviceHandle` trait → `spdk_rs::BdevIo<T>` + I/O channels → SPDK I/O operations

**Core SPDK Wrapper** (`io-engine/src/core/bdev.rs:31-49`):
```rust
pub struct Bdev<T: spdk_rs::BdevOps> {
    inner: spdk_rs::Bdev<T>,  // Direct wrapper around spdk-rs::Bdev
}

impl<T> Deref for Bdev<T> {
    type Target = spdk_rs::Bdev<T>;  // Transparent access to spdk-rs methods
}
```

## URI Factory System

### Central Dispatch (`io-engine/src/bdev/dev.rs:46-50`)

All block devices are created through a **unified URI-based factory system**:

```rust
pub fn parse(uri: &str) -> Result<Box<dyn BdevCreateDestroy<Error = BdevError>>, BdevError> {
    let url = url::Url::parse(uri)?;
    match url.scheme() {
        "aio" => Ok(Box::new(aio::Aio::try_from(&url)?)),
        "bdev" | "loopback" => Ok(Box::new(loopback::Loopback::try_from(&url)?)),
        "malloc" => Ok(Box::new(malloc::Malloc::try_from(&url)?)),
        "nvmf" | "nvmf+tcp" => Ok(Box::new(nvmx::NvmfDeviceTemplate::try_from(&url)?)),
        "pcie" => Ok(Box::new(nvme::NVMe::try_from(&url)?)),
        "uring" => Ok(Box::new(uring::Uring::try_from(&url)?)),
        "nexus" => Ok(Box::new(nx::Nexus::try_from(&url)?)),
        "lvol" => Ok(Box::new(lvs::Lvol::try_from(&url)?)),
        // ... additional schemes
    }
}
```

### Factory Pattern Benefits
- **Pluggable architecture**: Easy addition of new storage backends
- **Uniform configuration**: All devices configured via URI strings
- **Type safety**: Factory pattern ensures proper device instantiation
- **Loose coupling**: Components reference devices by URI, not concrete types

## Backend Categorization

### Physical Storage Backends (Thin Factories → SPDK I/O)

**Direct SPDK delegation** - minimal Mayastor logic:

- **AIO**: `aio:///path/to/file?blk_size=4096` - Linux async I/O
- **Malloc**: `malloc:///malloc0?size_mb=1024` - Memory-backed storage  
- **NVMe PCIe**: `pcie:///0000:01:00.0/1` - Direct PCIe NVMe access
- **NVMe-oF**: `nvmf://host:port/nqn.target` - Remote NVMe fabric
- **Uring**: `uring:///path/to/file` - Linux io_uring I/O
- **Null**: `null://` - Performance testing device

### Virtual/Filter Backends (Mayastor Logic + SPDK)

**Substantial Mayastor enhancements** beyond SPDK:

- **LVS**: `lvol://pool/volume` - Complex pool management and validation
- **Crypto**: Hardware-accelerated encryption with key management
- **Loopback**: `bdev:///existing_name` - Device aliasing and wrapping  
- **Nexus**: `nexus://volume-uuid` - Multi-replica volume aggregation

### Architectural Insight

**Implementation Strategy**:
```
Physical Backends: Parse URI → Call SPDK creation function
Virtual Backends:  Parse URI → Mayastor logic + SPDK integration
All I/O Logic:     Remains in SPDK for maximum performance
```

## Supporting Infrastructure

### Device Event System (`io-engine/src/core/device_events.rs`)
- Device lifecycle management with listener pattern
- Automatic event dispatching for device state changes
- Integration with monitoring and fault detection systems

### Device Monitoring (`io-engine/src/core/device_monitor.rs`)
- Device health monitoring and failure detection
- Real-time performance metrics collection
- Integration with reactor system for non-blocking monitoring

### Fault Injection Framework (`io-engine/src/core/fault_injection/`)
- **`bdev_io_injection.rs`** - I/O-level fault injection
- **`injection.rs`** - Core injection framework
- **`injection_api.rs`** - gRPC APIs for fault control
- **`injection_state.rs`** - State management for injection policies
- Built-in testing support with configurable error rates and types

### SPDK Device Integration (`io-engine/src/bdev/device.rs`)
- Bridges SPDK bdevs to Mayastor trait system
- Event integration and statistics collection
- Memory management for I/O contexts
- Error handling and translation from SPDK to Rust types

## Key Architectural Principles

### Layered Abstraction Strategy
```
Mayastor Traits (Unified interface)
    ↓
URI Factory System (Configuration & creation)
    ↓  
Backend Implementations (Parse URIs → SPDK calls)
    ↓
SPDK Native Bdevs (Actual I/O implementation)
    ↓
Hardware/OS (NVMe, AIO, etc.)
```

### Performance Preservation
- **Zero-cost abstractions**: Traits compile to direct SPDK function calls
- **Callback + async bridge**: Core I/O uses callbacks, async wrappers for ergonomics
- **Direct memory access**: DMA-aligned buffers flow through without copying
- **SPDK native I/O**: All performance-critical operations remain in SPDK

### Unified Interface Benefits
- **Heterogeneous storage**: Single interface for all backend types
- **Component decoupling**: Higher layers (Nexus) work with any backend
- **Testing simplification**: Consistent interface enables comprehensive testing
- **Operational consistency**: Uniform management across different storage types

## Source Code Locations

| Component | File | Purpose |
|-----------|------|---------|
| Core traits | `io-engine/src/core/block_device.rs` | BlockDevice trait definitions |
| URI factory | `io-engine/src/bdev/dev.rs` | Central dispatch system |
| SPDK integration | `io-engine/src/core/bdev.rs` | Core SPDK wrappers |
| Device wrapper | `io-engine/src/bdev/device.rs` | SPDK device integration |
| Infrastructure | `io-engine/src/core/device_*.rs` | Events, monitoring, injection |
| Backend implementations | `io-engine/src/bdev/*.rs` | Storage backend factories |