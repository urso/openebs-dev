---
title: SPDK Bdev Overview
type: note
permalink: spdk/spdk-bdev-overview
---

# SPDK Block Device (bdev) Overview

SPDK's **bdev** (block device) subsystem is the cornerstone of high-performance storage abstraction, providing a unified interface for all storage backends while enabling zero-copy, polled-mode I/O operations.

## Architecture at a Glance

The bdev layer serves as SPDK's universal storage interface, sitting between applications and diverse storage technologies:

```
┌─────────────────────────────────────────────┐
│           Applications & Targets            │
│    (NVMe-oF, iSCSI, vhost, custom apps)   │
├─────────────────────────────────────────────┤
│              SPDK Bdev Layer                │
│     (Unified I/O interface & management)   │
├─────────────────────────────────────────────┤
│    Virtual Bdevs (stackable filters)       │
│  ┌─────────┬─────────┬─────────┬─────────┐  │
│  │ Crypto  │ RAID    │  LVol   │ Compress│  │
│  └─────────┴─────────┴─────────┴─────────┘  │
├─────────────────────────────────────────────┤
│           Physical Storage Backends         │
│  ┌─────────┬─────────┬─────────┬─────────┐  │
│  │  NVMe   │   AIO   │ iSCSI   │  RBD    │  │
│  └─────────┴─────────┴─────────┴─────────┘  │
└─────────────────────────────────────────────┘
```

## Code References

### Core Interface Definition
- **Primary API**: `include/spdk/bdev.h`
  - Lines 104-124: I/O operation types (`SPDK_BDEV_IO_TYPE_*`)
  - Lines 425+: Core bdev structure definition
- **Module Interface**: `include/spdk/bdev_module.h`
  - Lines 307-400: Function table interface (`struct spdk_bdev_fn_table`)
  - Lines 425-620: Complete bdev structure with all capabilities

### Core Implementation
- **Registration Logic**: `lib/bdev/bdev.c:spdk_bdev_register()`
- **I/O Processing**: `lib/bdev/bdev.c` - Main subsystem implementation
- **Internal Structures**: `lib/bdev/bdev_internal.h`

## Key Features & Capabilities

### 1. **Unified I/O Interface**
All bdevs support a common set of 24+ I/O operations:

**Basic Operations:**
- `SPDK_BDEV_IO_TYPE_READ` / `WRITE` - Standard block I/O
- `SPDK_BDEV_IO_TYPE_FLUSH` - Cache synchronization  
- `SPDK_BDEV_IO_TYPE_RESET` - Device reset

**Advanced Operations:**
- `SPDK_BDEV_IO_TYPE_UNMAP` - Block deallocation (TRIM)
- `SPDK_BDEV_IO_TYPE_WRITE_ZEROES` - Efficient zero writes
- `SPDK_BDEV_IO_TYPE_COMPARE_AND_WRITE` - Atomic operations
- `SPDK_BDEV_IO_TYPE_COPY` - Hardware-accelerated copy

**Specialized Operations:**
- `SPDK_BDEV_IO_TYPE_ZONE_*` - Zoned storage management
- `SPDK_BDEV_IO_TYPE_NVME_*` - Direct NVMe command passthrough
- `SPDK_BDEV_IO_TYPE_SEEK_*` - Sparse file operations

### 2. **High-Performance Architecture**
- **Zero-Copy I/O**: Direct memory access without intermediate buffers
- **Polled Mode**: Eliminates interrupt overhead 
- **Per-Thread I/O Channels**: Lock-free, NUMA-aware processing
- **Async Callbacks**: Non-blocking I/O completion handling

### 3. **Rich Metadata Support**
```c
// From include/spdk/bdev_module.h:534-573
struct spdk_bdev {
    uint32_t md_len;                    // Metadata size per block
    bool md_interleave;                 // Metadata layout (inline vs separate)
    enum spdk_dif_type dif_type;        // Data Integrity Field type
    enum spdk_dif_pi_format dif_pi_format; // Protection Information format
    uint32_t dif_check_flags;           // DIF validation flags
};
```

### 4. **Advanced Storage Features**
- **Zoned Storage**: Native support for ZNS SSDs
- **Data Protection**: DIF/DIX integrity checking
- **QoS Integration**: Built-in rate limiting and prioritization (see [[SPDK QoS (Quality of Service) Support]])
- **Memory Domains**: Support for device-specific memory requirements

## Storage Backend Ecosystem

### **Physical Storage Backends**
| Backend | Use Case | Key Features | Documentation |
|---------|----------|--------------|---------------|
| **[[SPDK Bdev NVMe]]** | High-performance SSDs | Multipath, Opal, Zoned | `module/bdev/nvme/` |
| **[[SPDK Bdev AIO]]** | File/block devices | Linux AIO integration | `module/bdev/aio/` |
| **[[SPDK Bdev io_uring]]** | Modern Linux I/O | High-performance async I/O | `module/bdev/uring/` |
| **[[SPDK Bdev iSCSI]]** | Network storage | Remote block access | `module/bdev/iscsi/` |
| **[[SPDK Bdev RBD]]** | Ceph integration | Distributed storage | `module/bdev/rbd/` |
| **VirtIO** | Virtualization | Guest OS optimization | `module/bdev/virtio/` |

### **Virtual/Filter Bdevs**
| Virtual Bdev | Purpose | Stacking | Documentation |
|--------------|---------|----------|---------------|
| **[[SPDK Bdev Passthru]]** | Filter template | Any backend | `module/bdev/passthru/` |
| **[[SPDK Bdev Crypto]]** | Hardware encryption | Any backend | `module/bdev/crypto/` |
| **[[SPDK Bdev Compress]]** | Hardware compression | Any backend | `module/bdev/compress/` |
| **[[SPDK Bdev RAID Overview]]** | Redundancy/performance | Multiple backends | `module/bdev/raid/` |
| **[[SPDK LVS Overview]]** | Logical volumes | Single backend | `module/bdev/lvol/` |
| **Delay** | Testing/simulation | Any backend | `module/bdev/delay/` |

### **Testing & Development**
| Backend | Purpose | Use Case | Documentation |
|---------|---------|----------|---------------|
| **[[SPDK Bdev Malloc]]** | RAM storage | Development/testing | `module/bdev/malloc/` |
| **[[SPDK Bdev Null]]** | Performance testing | Benchmarking overhead | `module/bdev/null/` |
| **Error** | Fault injection | Reliability testing | `module/bdev/error/` |

## Composability & Stacking

One of bdev's most powerful features is the ability to stack virtual bdevs:

```
Application
    ↓
Crypto Bdev (AES encryption)
    ↓  
RAID1 Bdev (mirroring)
    ↓           ↓
NVMe Bdev    NVMe Bdev
(SSD #1)     (SSD #2)
```

**Example Stacking Scenarios:**
- **Performance**: `App → RAID0 → NVMe devices`
- **Security**: `App → Crypto → LVol → NVMe`  
- **Testing**: `App → Delay → Error → Malloc`
- **Caching**: `App → OCF Cache → NVMe + HDD`

## Development Interface

All bdev modules implement the standard `spdk_bdev_fn_table` interface:

```c
// From include/spdk/bdev_module.h:307-400
struct spdk_bdev_fn_table {
    int (*destruct)(void *ctx);                           // Cleanup
    void (*submit_request)(struct spdk_io_channel *ch,    // I/O processing
                          struct spdk_bdev_io *);
    bool (*io_type_supported)(void *ctx,                  // Capability query
                             enum spdk_bdev_io_type);
    struct spdk_io_channel *(*get_io_channel)(void *ctx); // Channel creation
    // Optional advanced functions...
};
```

## Performance Characteristics

### **Zero-Copy Benefits**
- **Memory Efficiency**: No intermediate buffer allocation
- **CPU Efficiency**: Eliminates memory copies
- **Cache Efficiency**: Better CPU cache utilization

### **Polled Mode Advantages**  
- **Low Latency**: ~1-2μs for NVMe operations
- **High IOPS**: Millions of operations per second
- **Predictable Performance**: No interrupt jitter

### **NUMA Optimization**
- **Per-Thread Channels**: Avoid cross-socket memory access
- **Local Memory Allocation**: Optimal memory placement
- **Thread Affinity**: CPU and memory locality

## Integration Points

### **With SPDK Components**
- **[[SPDK LVS Overview]]**: Logical volume management built on bdev
- **[[SPDK RAID0 Overview]]**: RAID implementations using bdev interface
- **NVMe-oF Target**: Exports bdevs as NVMe namespaces
- **iSCSI Target**: Exports bdevs as SCSI LUNs

### **With Applications**
- **Direct Integration**: Applications use bdev API directly
- **Target Integration**: Through SPDK target applications
- **Custom Protocols**: Build new storage protocols on bdev

## Management & Configuration

### **RPC Interface**
All bdevs support JSON-RPC management:
```bash
# List all bdevs
./scripts/rpc.py bdev_get_bdevs

# Get specific bdev info  
./scripts/rpc.py bdev_get_bdevs -b nvme0n1

# Performance statistics
./scripts/rpc.py bdev_get_iostat
```

### **Dynamic Management**
- **Hot-plug Support**: Add/remove devices at runtime
- **Configuration Persistence**: Save/restore bdev configurations
- **Health Monitoring**: Real-time status and error reporting

## Next Steps

### **Development & Implementation**
- **[[SPDK Bdev Development Guide]]**: Learn to implement custom bdev modules
- **[[SPDK Bdev Capability Matrix]]**: Compare features across implementations

### **Physical Storage Backends**
- **[[SPDK Bdev NVMe]]**: High-performance NVMe SSD integration
- **[[SPDK Bdev AIO]]**: Linux AIO file and block device support  
- **[[SPDK Bdev io_uring]]**: Modern async I/O with io_uring
- **[[SPDK Bdev iSCSI]]**: Network-attached storage access
- **[[SPDK Bdev RBD]]**: Ceph distributed storage integration

### **Virtual & Filter Bdevs**
- **[[SPDK Bdev Passthru]]**: Template for implementing filter bdevs
- **[[SPDK Bdev Crypto]]**: Hardware-accelerated encryption
- **[[SPDK Bdev Compress]]**: Hardware-accelerated compression
- **[[SPDK Bdev RAID Overview]]**: RAID levels and configuration

### **Storage Composition & Management**
- **[[SPDK LVS Overview]]**: Logical volume management system
- **[[SPDK RAID0 Overview]]**: High-performance RAID0 implementation

### **Testing & Development Tools**
- **[[SPDK Bdev Malloc]]**: Memory-based storage for testing
- **[[SPDK Bdev Null]]**: Performance benchmarking backend

---

The bdev subsystem represents SPDK's approach to high-performance storage abstraction: provide a rich, unified interface while maintaining the flexibility to optimize for specific storage technologies and use cases.