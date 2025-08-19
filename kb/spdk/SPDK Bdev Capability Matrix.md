---
title: SPDK Bdev Capability Matrix
type: note
permalink: spdk/spdk-bdev-capability-matrix
---

# SPDK Bdev Capability Matrix

Comprehensive comparison of features and capabilities across all SPDK bdev implementations. This matrix helps developers choose the right backend and understand feature availability.

## Feature Comparison Overview

| Backend | Type | Basic I/O | Metadata | Zoned | Memory Domains | Accel Seq | Config JSON | Hot-plug |
|---------|------|-----------|----------|-------|----------------|-----------|-------------|----------|
| **Physical Backends** |
| NVMe | Physical | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| AIO | Physical | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| io_uring | Physical | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| iSCSI | Physical | ✅ | ❓ | ❌ | ❌ | ❌ | ✅ | ✅ |
| RBD | Physical | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| VirtIO | Physical | ✅ | ❓ | ❌ | ❌ | ❌ | ✅ | ❌ |
| DAOS | Physical | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| xNVMe | Physical | ✅ | ❓ | ❓ | ❌ | ❌ | ❌ | ❌ |
| **Virtual/Filter Backends** |
| Passthru | Virtual | ✅ | 🔄 | 🔄 | ✅ | ❌ | ✅ | 🔄 |
| Crypto | Virtual | ✅ | 🔄 | 🔄 | ✅ | ✅ | ✅ | 🔄 |
| Compress | Virtual | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | 🔄 |
| Delay | Virtual | ✅ | 🔄 | 🔄 | ✅ | ❌ | ✅ | 🔄 |
| Error | Virtual | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | 🔄 |
| Split | Virtual | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | 🔄 |
| Zone Block | Virtual | ✅ | 🔄 | ✅ | ❌ | ❌ | ✅ | 🔄 |
| **RAID & Composition** |
| RAID0 | Composition | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | ✅ |
| RAID1 | Composition | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | ✅ |
| RAID5f | Composition | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | ✅ |
| Concat | Composition | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | ✅ |
| LVol | Composition | ✅ | ✅ | ❓ | ❌ | ❌ | ✅ | ❌ |
| **Testing & Synthetic** |
| Malloc | Synthetic | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| Null | Synthetic | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| FTL | Synthetic | ✅ | ❓ | ❌ | ❌ | ❌ | ✅ | ❌ |
| **Caching** |
| OCF | Cache | ✅ | 🔄 | 🔄 | ❌ | ❌ | ✅ | ❌ |

**Legend:**
- ✅ **Fully Supported** - Native implementation
- 🔄 **Inherited** - Passes through to base bdev  
- ❓ **Partial/Unknown** - Limited or undocumented support
- ❌ **Not Supported** - Feature not available

## Detailed Feature Analysis

### I/O Type Support Matrix

Based on code analysis of `io_type_supported` functions across modules:

| I/O Type | NVMe | AIO | Malloc | Null | Crypto | RAID0 | LVol |
|----------|------|-----|--------|------|--------|-------|------|
| **Basic Operations** |
| READ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| WRITE | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| FLUSH | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| RESET | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Advanced Operations** |
| UNMAP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| WRITE_ZEROES | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| COMPARE | ✅ | ❌ | ✅ | ❌ | ✅ | ❓ | ❓ |
| COMPARE_AND_WRITE | ✅ | ❌ | ✅ | ❌ | ✅ | ❓ | ❓ |
| COPY | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **NVMe Specific** |
| NVME_ADMIN | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| NVME_IO | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| NVME_IO_MD | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Zoned Storage** |
| GET_ZONE_INFO | ✅ | ❌ | ❌ | ❌ | 🔄 | ❌ | ❌ |
| ZONE_MANAGEMENT | ✅ | ❌ | ❌ | ❌ | 🔄 | ❌ | ❌ |
| ZONE_APPEND | ✅ | ❌ | ❌ | ❌ | 🔄 | ❌ | ❌ |
| **File Operations** |
| SEEK_HOLE | ❌ | ✅ | ❌ | ❌ | 🔄 | ❌ | ❌ |
| SEEK_DATA | ❌ | ✅ | ❌ | ❌ | 🔄 | ❌ | ❌ |

### Code References for Capability Detection

#### Function Table Locations
- **NVMe**: `module/bdev/nvme/bdev_nvme.c` (complex, device-dependent)
- **AIO**: `module/bdev/aio/bdev_aio.c:814-822`
- **Malloc**: `module/bdev/malloc/bdev_malloc.c:696-704`
- **Crypto**: `module/bdev/crypto/vbdev_crypto.c:772-780`
- **Passthru**: `module/bdev/passthru/vbdev_passthru.c:549-557`

#### I/O Type Support Functions
```c
// Example from module/bdev/malloc/bdev_malloc.c:651-664
static bool
bdev_malloc_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
{
    switch (io_type) {
    case SPDK_BDEV_IO_TYPE_READ:
    case SPDK_BDEV_IO_TYPE_WRITE:
    case SPDK_BDEV_IO_TYPE_FLUSH:
    case SPDK_BDEV_IO_TYPE_RESET:
    case SPDK_BDEV_IO_TYPE_UNMAP:
    case SPDK_BDEV_IO_TYPE_WRITE_ZEROES:
    case SPDK_BDEV_IO_TYPE_COMPARE:
    case SPDK_BDEV_IO_TYPE_COMPARE_AND_WRITE:
        return true;
    default:
        return false;
    }
}
```

## Performance Characteristics

### Latency Comparison (Typical)
| Backend | Read Latency | Write Latency | Notes |
|---------|-------------|---------------|-------|
| NVMe | ~2-5μs | ~5-15μs | Direct hardware access |
| AIO | ~50-200μs | ~100-500μs | Kernel syscall overhead |
| Malloc | <1μs | <1μs | Memory-only operations |
| Null | <0.1μs | <0.1μs | No actual I/O |
| Crypto | +5-20μs | +10-50μs | Encryption overhead |
| RAID0 | ~Base/N | ~Base/N | N = number of drives |

### IOPS Scalability
| Backend | Single Queue | Multi Queue | Scaling Factor |
|---------|-------------|-------------|----------------|
| NVMe | ~500K | ~2M+ | Excellent |
| AIO | ~50K | ~200K | Good |
| Malloc | ~1M+ | ~5M+ | Excellent |
| Crypto | ~Base*0.8 | ~Base*0.9 | Hardware dependent |

## Use Case Recommendations

### **High Performance Applications**
- **Primary**: NVMe bdev (direct hardware access)
- **Stacking**: Minimal layers (avoid unnecessary virtual bdevs)
- **Configuration**: Dedicated CPU cores, NUMA optimization

### **Development & Testing**
- **Primary**: Malloc bdev (predictable, fast)
- **Error Testing**: Error bdev for fault injection
- **Performance Testing**: Null bdev for overhead measurement

### **Storage Composition**
- **Redundancy**: RAID1 or RAID5f
- **Performance**: RAID0 or LVol with multiple base bdevs
- **Security**: Crypto bdev with hardware acceleration

### **Network Storage**
- **Remote Block**: iSCSI bdev
- **Distributed**: RBD bdev (Ceph integration)
- **Cloud**: Varies by provider requirements

### **Virtualization**
- **Guest OS**: VirtIO bdev
- **Host Sharing**: LVol for multi-tenant scenarios
- **Migration**: Backends supporting hot-plug

## Feature Evolution Roadmap

### **Emerging Capabilities**
- **Acceleration Sequence Support**: Growing across virtual bdevs
- **Memory Domain Integration**: Expanding beyond physical backends  
- **Zoned Storage**: More virtual bdev support planned
- **Copy Offload**: Hardware acceleration adoption

### **Compatibility Notes**
- **Virtual Bdev Stacking**: Most features inherited from base
- **RAID Limitations**: Complex operations may not be supported
- **Metadata Propagation**: Not all virtual bdevs preserve metadata

## Selection Decision Tree

```
Storage Requirement?
├── Performance Critical?
│   ├── Local Storage → NVMe
│   └── Network Storage → iSCSI/RBD
├── Development/Testing?
│   ├── Fast Iteration → Malloc  
│   └── Fault Testing → Error + Base
├── Data Protection?
│   ├── Encryption → Crypto + Base
│   └── Redundancy → RAID + Physical
└── Storage Management?
    ├── Thin Provisioning → LVol
    └── Partitioning → Split
```


---

This matrix is maintained based on code analysis and testing. Capabilities may vary by SPDK version and specific device support. Always verify features in your target environment.