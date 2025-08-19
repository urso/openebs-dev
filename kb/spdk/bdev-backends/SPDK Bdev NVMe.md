---
title: SPDK Bdev NVMe
type: note
permalink: spdk/bdev-backends/spdk-bdev-nvme
---

# SPDK Bdev NVMe Backend

The NVMe bdev backend provides direct access to NVMe storage devices with full hardware feature support, including multipath, encryption (Opal), zoned storage, and high-performance I/O processing.

## Architecture Overview

The NVMe bdev backend directly interfaces with NVMe devices through SPDK's userspace NVMe driver, bypassing the kernel for maximum performance:

```
Application Layer
       ↓
SPDK Bdev Interface  
       ↓
NVMe Bdev Module ← → NVMe Controller Management
       ↓
SPDK NVMe Driver (userspace)
       ↓
NVMe Device (PCIe/NVMe-oF)
```

## Code References

### Core Implementation
- **Main Module**: `module/bdev/nvme/bdev_nvme.c`
- **Header**: `module/bdev/nvme/bdev_nvme.h`  
- **RPC Interface**: `module/bdev/nvme/bdev_nvme_rpc.c`
- **Build Config**: `module/bdev/nvme/Makefile`

### Key Functions
- **Controller Attachment**: `module/bdev/nvme/bdev_nvme.c:bdev_nvme_create_ctrlr()`
- **Namespace Discovery**: `module/bdev/nvme/bdev_nvme.c:bdev_nvme_create_bdevs()`
- **I/O Processing**: Complex, device-dependent submission logic
- **Multipath Logic**: `module/bdev/nvme/bdev_nvme.c:bdev_nvme_failover()`

### Function Table
The NVMe backend implements a comprehensive function table with device-specific capabilities:
```c
// Complex implementation - capabilities vary by device
// See module/bdev/nvme/bdev_nvme.c for complete function table
```

## Supported Features

### ✅ **Fully Supported**
- **Basic I/O**: READ, WRITE, FLUSH, RESET
- **Advanced I/O**: UNMAP, WRITE_ZEROES, COMPARE, COMPARE_AND_WRITE, COPY
- **NVMe Specific**: NVME_ADMIN, NVME_IO, NVME_IO_MD, NVME_IOV_MD
- **Zoned Storage**: GET_ZONE_INFO, ZONE_MANAGEMENT, ZONE_APPEND (ZNS devices)
- **Metadata**: DIF/DIX protection, separate/interleaved metadata
- **Security**: Opal encryption/decryption
- **Multipath**: Automatic failover between controllers
- **Hot-plug**: Dynamic device addition/removal

### ⚠️ **Device Dependent**
- **Zoned Support**: Only on ZNS SSDs
- **Metadata Format**: Varies by device configuration
- **Copy Operations**: Requires device support
- **Opal Encryption**: Requires TCG Opal support

## Configuration Examples

### Basic NVMe Attachment
```bash
# Attach NVMe controller
./scripts/rpc.py bdev_nvme_attach_controller \
    -b nvme0 \
    -t pcie \
    -a 0000:01:00.0

# Result: Creates nvme0n1, nvme0n2, etc. based on namespaces
```

### NVMe-oF (Fabrics) Attachment
```bash
# Attach NVMe-oF controller
./scripts/rpc.py bdev_nvme_attach_controller \
    -b nvme_remote \
    -t tcp \
    -a 192.168.1.100 \
    -s 4420 \
    -f ipv4 \
    -n nqn.2019-05.io.spdk:cnode1
```

### Multipath Configuration
```bash
# Attach multiple paths to same subsystem
./scripts/rpc.py bdev_nvme_attach_controller \
    -b nvme_mp \
    -t tcp \
    -a 192.168.1.100 \
    -s 4420 \
    -f ipv4 \
    -n nqn.2019-05.io.spdk:cnode1 \
    --multipath

./scripts/rpc.py bdev_nvme_attach_controller \
    -b nvme_mp \
    -t tcp \
    -a 192.168.1.101 \
    -s 4420 \
    -f ipv4 \
    -n nqn.2019-05.io.spdk:cnode1 \
    --multipath
```

### Opal Encryption Setup
```bash
# Set up Opal encryption
./scripts/rpc.py bdev_opal_create \
    -b nvme0n1 \
    -n opal_nvme0n1 \
    -p opal_password
```

## Performance Characteristics

### **Latency** (Typical for local NVMe SSD)
- **Read**: 10-50μs (including SPDK overhead)  
- **Write**: 20-100μs (depends on media type)
- **Queue Depth Impact**: Lower latency at QD=1, optimal throughput at QD=32+

### **IOPS Scaling**
- **Single Queue**: 100K-500K IOPS
- **Multiple Queues**: 1M-4M+ IOPS (limited by device)
- **Scaling Factor**: Linear with queue pairs up to device limits

### **Throughput**
- **Sequential Read**: Up to device specification (3-7 GB/s typical)
- **Sequential Write**: Device-dependent (2-5 GB/s typical)  
- **Random Performance**: Significantly higher than kernel drivers

### **CPU Efficiency**
- **Polling Overhead**: ~5-15% CPU per million IOPS
- **NUMA Impact**: Significant - keep device and CPU on same socket
- **Interrupt Elimination**: Major performance advantage over kernel

## Advanced Features

### **Multipath High Availability**
```bash
# Check multipath status
./scripts/rpc.py bdev_nvme_get_controllers

# Manual failover (automatic in normal operation)
./scripts/rpc.py bdev_nvme_set_preferred_path nvme_mp tcp://192.168.1.101:4420
```

### **Zoned Storage Operations**
```bash
# Get zone information (ZNS devices only)
./scripts/rpc.py bdev_zone_get_info nvme0n1

# Zone management
./scripts/rpc.py bdev_zone_management nvme0n1 0 open
```

### **Device Statistics**
```bash
# Detailed NVMe statistics
./scripts/rpc.py bdev_nvme_get_iostat

# SMART information
./scripts/rpc.py bdev_nvme_get_smart_log nvme0
```

## Limitations & Considerations

### **Hardware Requirements**
- **VFIO/UIO**: Requires userspace driver setup (`scripts/setup.sh`)
- **IOMMU**: Must be properly configured for DMA operations
- **Hugepages**: Required for optimal performance
- **CPU Cores**: Dedicated cores recommended for high IOPS

### **Operating System Support**
- **Linux**: Full support with VFIO/UIO
- **FreeBSD**: Supported with some limitations
- **Windows**: Limited support

### **Device Compatibility**
- **NVMe 1.0+**: Basic support
- **NVMe 1.3+**: Full feature support
- **Vendor Specific**: Some features may require specific vendors

### **Network Considerations** (NVMe-oF)
- **Network Latency**: Directly impacts I/O latency
- **Bandwidth**: Must match or exceed device capability
- **Reliability**: Network issues affect storage availability

## Troubleshooting

### **Common Issues**
```bash
# Device not visible
./scripts/setup.sh  # Ensure proper driver binding

# Check device binding
ls /sys/bus/pci/drivers/vfio-pci/
ls /sys/bus/pci/drivers/uio_pci_generic/

# Performance issues
./scripts/rpc.py bdev_nvme_get_iostat  # Check queue depth utilization
```

### **Debug Information**
```bash
# Enable detailed logging
./app/spdk_tgt/spdk_tgt --log-level=DEBUG --log-component=bdev_nvme

# Controller information
./scripts/rpc.py bdev_nvme_get_controllers
```

## Integration Examples

### **With Logical Volumes**
```bash
# Create LVS on NVMe
./scripts/rpc.py bdev_lvol_create_lvstore nvme0n1 lvs0
./scripts/rpc.py bdev_lvol_create -l lvs0 -n lvol0 -s 1073741824
```

### **With RAID**
```bash
# RAID0 across multiple NVMe devices
./scripts/rpc.py bdev_raid_create -n raid0_nvme -z 64 -r 0 -b "nvme0n1 nvme1n1"
```

### **With Encryption**
```bash
# Stack crypto on NVMe
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto_nvme0n1 crypto_aesni_mb AES_CBC
```

## Best Practices

### **Performance Optimization**
1. **NUMA Alignment**: Match NVMe PCIe slot to CPU socket
2. **Queue Depth**: Start with 32, tune based on workload
3. **Block Size**: Align to device optimal transfer size
4. **CPU Cores**: Dedicate cores for high-IOPS workloads

### **Reliability**
1. **Multipath**: Configure for critical applications
2. **Monitoring**: Track SMART data and error rates
3. **Thermal**: Monitor device temperature under load
4. **Firmware**: Keep device firmware updated

### **Security**
1. **Opal Encryption**: Use for data-at-rest protection
2. **Secure Erase**: Properly sanitize devices
3. **Access Control**: Limit device access permissions

## Code Examples

### **Custom NVMe Integration**
```c
// Example: Custom NVMe bdev creation
#include "spdk/bdev.h"
#include "spdk/nvme.h"

// Attach and create bdevs programmatically
// See module/bdev/nvme/bdev_nvme.c for complete implementation
```

---

The NVMe bdev backend represents SPDK's flagship storage interface, providing direct hardware access with maximum performance and full NVMe feature support. It serves as the foundation for most high-performance SPDK deployments.