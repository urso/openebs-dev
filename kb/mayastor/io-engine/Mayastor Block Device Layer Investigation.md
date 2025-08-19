---
title: Mayastor Block Device Layer Investigation
type: note
permalink: docs/mayastor-block-device-layer-investigation
---

# Mayastor Block Device Layer (bdev) Investigation

## Overview
The Mayastor Block Device Layer provides a comprehensive abstraction over SPDK's bdev system, consisting of high-level Rust traits, URI-based device factories, and extensive infrastructure for device management, monitoring, and fault injection.

## Relationship to SPDK
As documented in [[SPDK Bdev Overview]], SPDK's bdev subsystem provides a unified interface for storage backends with zero-copy, polled-mode I/O. Mayastor builds upon this foundation by adding:
- Rust-safe trait abstractions over SPDK's C APIs
- URI-based device configuration and factory pattern
- Comprehensive error handling and async/await integration
- Built-in fault injection, monitoring, and event systems

## Core Abstraction Layer (`io-engine/src/core/`)

### Three-Layer Trait Architecture

**Primary Traits** (`io-engine/src/core/block_device.rs:53-92`):

**1. BlockDevice Trait** - Device metadata and capabilities:
```rust
#[async_trait(?Send)]
pub trait BlockDevice {
    fn size_in_bytes(&self) -> u64;
    fn block_len(&self) -> u64;
    fn num_blocks(&self) -> u64;
    fn uuid(&self) -> Uuid;                            // Note: not Option<Uuid>
    fn product_name(&self) -> String;
    fn driver_name(&self) -> String;
    fn device_name(&self) -> String;
    fn alignment(&self) -> u64;
    fn io_type_supported(&self, io_type: IoType) -> bool;
    async fn io_stats(&self) -> Result<BlockDeviceIoStats, CoreError>;
    fn open(&self, read_write: bool) -> Result<Box<dyn BlockDeviceDescriptor>, CoreError>;
    fn get_io_controller(&self) -> Option<Box<dyn DeviceIoController>>;
    fn add_event_listener(&self, listener: DeviceEventSink) -> Result<(), CoreError>;
}
```

**2. BlockDeviceDescriptor Trait** (`io-engine/src/core/block_device.rs:97-115`) - Opened device:
```rust
#[async_trait(?Send)]
pub trait BlockDeviceDescriptor {
    fn get_device(&self) -> Box<dyn BlockDevice>;
    fn device_name(&self) -> String;
    fn into_handle(self: Box<Self>) -> Result<Box<dyn BlockDeviceHandle>, CoreError>;
    fn get_io_handle(&self) -> Result<Box<dyn BlockDeviceHandle>, CoreError>;
    fn unclaim(&self);
    async fn get_io_handle_nonblock(&self) -> Result<Box<dyn BlockDeviceHandle>, CoreError>;
}
```

**3. BlockDeviceHandle Trait** (`io-engine/src/core/block_device.rs:145+`) - I/O operations:
```rust
#[async_trait(?Send)]
pub trait BlockDeviceHandle {
    fn get_device(&self) -> &dyn BlockDevice;
    fn dma_malloc(&self, size: u64) -> Result<DmaBuf, DmaError>;
    
    // Callback-based I/O (core operations)
    fn readv_blocks(&self, iovs: &mut [IoVec], offset_blocks: u64, num_blocks: u64,
                   opts: ReadOptions, cb: IoCompletionCallback, cb_arg: IoCompletionCallbackArg) 
                   -> Result<(), CoreError>;
    
    // Async wrappers over callback versions  
    async fn readv_blocks_async(&self, iovs: &mut [IoVec], offset_blocks: u64,
                               num_blocks: u64, opts: ReadOptions) -> Result<(), CoreError>;
    // Similar patterns for write, unmap, reset, etc.
}
```

### Relationship to spdk-rs Wrappers

The traits are **higher-level abstractions** that wrap spdk-rs types:

**Core SPDK Integration** (`io-engine/src/core/bdev.rs:31-49`):
```rust
pub struct Bdev<T: spdk_rs::BdevOps> {
    inner: spdk_rs::Bdev<T>,  // Direct wrapper around spdk-rs::Bdev
}

impl<T> Deref for Bdev<T> {
    type Target = spdk_rs::Bdev<T>;  // Transparent access to spdk-rs methods
}
```

**Mapping to spdk-rs types:**
- `BlockDevice` trait → `spdk_rs::Bdev<T>` → SPDK `spdk_bdev`
- `BlockDeviceDescriptor` trait → `spdk_rs::BdevDesc<T>` → SPDK `spdk_bdev_desc`
- `BlockDeviceHandle` trait → `spdk_rs::BdevIo<T>` + I/O channels → SPDK I/O operations

## Supporting Infrastructure (`io-engine/src/core/`)

### Core Infrastructure Files
- **`bdev.rs`** - SPDK bdev wrappers, sharing logic, and core integration
- **`descriptor.rs`** - BlockDeviceDescriptor implementations
- **`handle.rs`** - BlockDeviceHandle implementations  
- **`device_events.rs`** - Device event system for lifecycle management
- **`device_monitor.rs`** - Device health monitoring and failure detection
- **`mempool.rs`** - Memory pool management for I/O contexts
- **`io_device.rs`** - I/O device abstractions and utilities

### Comprehensive Statistics System (`io-engine/src/core/block_device.rs:13-48`)
```rust
#[derive(Debug, Default, Clone, Copy, Merge)]
pub struct BlockDeviceIoStats {
    pub num_read_ops: u64,
    pub num_write_ops: u64,
    pub bytes_read: u64,
    pub bytes_written: u64,
    pub num_unmap_ops: u64,
    pub bytes_unmapped: u64,
    pub read_latency_ticks: u64,
    pub write_latency_ticks: u64,
    // ... comprehensive latency tracking with min/max/average
    pub tick_rate: u64,  // For time normalization
}
```

### Fault Injection Framework (`io-engine/src/core/fault_injection/`)
- **`bdev_io_injection.rs`** - I/O-level fault injection
- **`injection.rs`** - Core injection framework
- **`injection_api.rs`** - gRPC APIs for fault injection control
- **`injection_state.rs`** - State management for injection policies
- Built-in testing support with configurable error rates and types

## Device Factory System (`io-engine/src/bdev/`)

### URI-Based Factory Pattern (`io-engine/src/bdev/dev.rs:46-50`)

**Central Dispatch Function**:
```rust
pub fn parse(uri: &str) -> Result<Box<dyn BdevCreateDestroy<Error = BdevError>>, BdevError> {
    let url = url::Url::parse(uri)?;
    match url.scheme() {
        "aio" => Ok(Box::new(aio::Aio::try_from(&url)?)),
        "bdev" | "loopback" => Ok(Box::new(loopback::Loopback::try_from(&url)?)),
        "ftl" => Ok(Box::new(ftl::Ftl::try_from(&url)?)),
        "malloc" => Ok(Box::new(malloc::Malloc::try_from(&url)?)),
        "null" => Ok(Box::new(null_bdev::Null::try_from(&url)?)),
        "nvmf" | "nvmf+tcp" | "nvmf+rdma+tcp" => Ok(Box::new(nvmx::NvmfDeviceTemplate::try_from(&url)?)),
        "pcie" => Ok(Box::new(nvme::NVMe::try_from(&url)?)),
        "uring" => Ok(Box::new(uring::Uring::try_from(&url)?)),
        "nexus" => Ok(Box::new(nx::Nexus::try_from(&url)?)),
        "lvol" => Ok(Box::new(lvs::Lvol::try_from(&url)?)),
        // ... additional schemes
    }
}
```

### Storage Backend Implementations

**Physical Storage Backends** (Thin Factories → SPDK does I/O):

**1. AIO - Linux Asynchronous I/O** (`io-engine/src/bdev/aio.rs`)
- **URI**: `aio:///path/to/file?blk_size=4096&uuid=...`
- **Purpose**: File-based storage using Linux AIO
- **Implementation**: Calls SPDK's `create_aio_bdev()` directly
- **Use Case**: Local file-backed storage, development, testing

**2. Malloc - Memory Storage** (`io-engine/src/bdev/malloc.rs:178-200`)
- **URI**: `malloc:///malloc0?size_mb=1024&blk_size=512`
- **Purpose**: Memory-backed storage using huge pages
- **Implementation**: 
```rust
async fn create(&self) -> Result<String, Self::Error> {
    let errno = unsafe {
        let opts = malloc_bdev_opts {
            name: cname.as_ptr(),
            num_blocks: self.num_blocks,
            block_size: self.blk_size,
            // ...
        };
        create_malloc_disk(&mut bdev, &opts)  // Direct SPDK call
    };
}
```
- **Use Case**: Testing, caching, temporary storage

**3. NVMe PCIe** (`io-engine/src/bdev/nvme.rs`)
- **URI**: `pcie:///0000:01:00.0/1` (PCI address/namespace)
- **Purpose**: Direct PCIe NVMe device access
- **Implementation**: Calls SPDK NVMe probe and attachment functions
- **Use Case**: High-performance local NVMe storage

**4. NVMe-oF (Modern Implementation)** (`io-engine/src/bdev/nvmx/`)
- **URI**: `nvmf://target-ip:port/nqn?hostnqn=...&hostid=...`
- **Purpose**: Remote NVMe storage via fabric protocols
- **Implementation**: Complex connection management with automatic reconnection
- **Key Files**:
  - `device.rs` - Device template and creation logic
  - `controller.rs` - NVMe-oF controller lifecycle management
  - `channel.rs` - I/O channel management
  - `namespace.rs` - Namespace handling
- **Use Case**: Distributed storage, remote storage access

**5. Uring - io_uring I/O** (`io-engine/src/bdev/uring.rs`)
- **URI**: `uring:///path/to/file`
- **Purpose**: High-performance I/O using Linux io_uring
- **Implementation**: Calls SPDK's uring bdev creation functions
- **Use Case**: Modern Linux async I/O with kernel bypass

**6. Additional Physical Backends**:
- **`null_bdev.rs`** - Null device for performance testing (`null://`)
- **`ftl.rs`** - Flash Translation Layer support (`ftl://`)

### Virtual/Filter Bdevs (Mix of SPDK + Mayastor Logic)

**1. LVS - Logical Volume Store** (`io-engine/src/bdev/lvs.rs:189-229`)
- **URI**: `lvol:///$name?size=$size&lvs=lvs:///$name?mode=$mode&disk=$disk`
- **Purpose**: Logical volume management with thin provisioning
- **Implementation**: Substantial Mayastor logic:
```rust
async fn create(&self) -> Result<String, Self::Error> {
    let lvs = self.lvs.create().await?;              // Mayastor LVS management
    self.lvs.destroy_lvol(&self.name).await.ok();   // Cleanup existing
    lvs.create_lvol(&self.name, self.size, None, false, None).await  // Mayastor Lvol creation
}
```
- **Integration**: Uses `crate::lvs::Lvs::create_or_import()` - complex pool management logic
- **Use Case**: Advanced storage management, snapshots, thin provisioning

**2. Crypto - Encryption Layer** (`io-engine/src/bdev/crypto.rs:247-265`)
- **Purpose**: Hardware-accelerated encryption for any base bdev
- **Implementation**: SPDK wrapper + key management:
```rust
pub async fn create_crypto_vbdev(
    base_bdev_name: &str,
    crypto_vbdev_name: &str,
    key_params: &EncryptionKey
) -> Result<(), BdevError> {
    let key = add_key_user(key_params, crypto_vbdev_name.to_string())?;  // Mayastor key tracking
    let ret = unsafe { create_crypto_disk(crypto_opts_ptr) };            // SPDK encryption
}
```
- **Added Logic**: Global key management (`KEY_CRYPTO_VBDEV_MAP`) tracks which vbdevs use which keys
- **Use Case**: Transparent encryption with hardware acceleration

**3. Loopback - Device Wrapping** (`io-engine/src/bdev/loopback.rs`)
- **URI**: `bdev:///existing_bdev_name`, `loopback:///existing_bdev_name`
- **Purpose**: Wrap existing bdev with new alias/configuration
- **Implementation**: Thin wrapper around SPDK passthrough
- **Use Case**: Device aliasing, configuration changes

### Device Integration Layer (`io-engine/src/bdev/device.rs`)

**SPDK Device Wrapper** - Bridges SPDK bdevs to Mayastor traits:
- **Event Integration**: Device event dispatching and listener management
- **Statistics Collection**: Real-time I/O metrics with comprehensive latency tracking
- **Fault Injection**: Integration with fault injection framework for testing
- **Memory Management**: I/O context pool management (`BDEV_IOCTX_POOL`)
- **Error Handling**: Translation from SPDK errors to Rust error types

```rust
/// Wrapper around native SPDK block devices, which mimics target SPDK block
/// device as an abstract BlockDevice instance.
pub struct SpdkBlockDevice {
    // Implementation bridges SPDK C APIs to Rust trait system
}
```

## Key Architectural Insights

### 1. **Layered Abstraction Strategy**
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

### 2. **Factory vs Implementation Pattern**
- **Physical Backends**: Thin factories that parse URIs and call SPDK creation functions
- **Virtual Backends**: Thicker wrappers adding Mayastor-specific logic (LVS pools, crypto key management)
- **All I/O Logic**: Remains in SPDK for maximum performance

### 3. **Comprehensive Infrastructure**
- **Event System**: Device lifecycle management with listener pattern
- **Fault Injection**: Built-in testing framework at the foundational layer
- **Statistics**: Real-time performance monitoring with tick-based precision
- **Memory Management**: DMA-aligned buffer pools for zero-copy I/O

### 4. **Async/Callback Bridge**
- **Core Operations**: Callback-based (matches SPDK's C API model)
- **Async Wrappers**: Convert callbacks to futures for ergonomic Rust code
- **Performance**: Zero-cost abstractions compile to direct SPDK function calls

## Relationship to Other Mayastor Components

### Integration with Nexus Layer
- **Nexus as Consumer**: Uses BlockDevice traits to aggregate multiple storage children
- **Child Management**: Nexus children are BlockDevice implementations (documented in [[Mayastor Nexus Architecture]])
- **HA Support**: NVMe reservations and path management (documented in [[Mayastor HA Research Findings]])

### Integration with SPDK Ecosystem
- **Built on Foundation**: Leverages all SPDK bdev capabilities documented in [[SPDK Bdev Overview]]
- **Backend Compatibility**: Supports all major SPDK bdev types ([[SPDK Bdev NVMe]], [[SPDK Bdev AIO]], [[SPDK LVS Overview]])
- **Performance Characteristics**: Maintains SPDK's zero-copy, polled-mode benefits

### Memory and I/O Integration
- **DMA Management**: Integration with memory pools and DMA-aligned allocations
- **Reactor Integration**: Works within SPDK's reactor-based threading model (documented in previous research)
- **Event Loop Integration**: Device events integrate with SPDK's event processing

## Source Code Summary

### Core Abstraction (`io-engine/src/core/`)
- **Primary traits**: `block_device.rs:53-145+`
- **SPDK integration**: `bdev.rs:31-49`
- **Statistics**: `block_device.rs:13-48`
- **Fault injection**: `fault_injection/` directory
- **Infrastructure**: `descriptor.rs`, `handle.rs`, `device_events.rs`, `device_monitor.rs`, `mempool.rs`

### Device Factories (`io-engine/src/bdev/`)
- **URI dispatch**: `dev.rs:46-50`
- **SPDK wrapper**: `device.rs`
- **Physical backends**: `aio.rs`, `malloc.rs`, `nvme.rs`, `uring.rs`, `nvmx/`
- **Virtual backends**: `lvs.rs`, `crypto.rs`, `loopback.rs`, `ftl.rs`
- **Utilities**: `util/uri.rs`

The Block Device Layer forms the foundational abstraction that enables Mayastor's unified storage interface while maintaining SPDK's performance characteristics and extending them with Rust safety, comprehensive error handling, and advanced features like built-in fault injection and monitoring.