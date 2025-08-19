---
title: SPDK Bdev AIO
type: note
permalink: spdk/bdev-backends/spdk-bdev-aio
---

# SPDK Bdev AIO Backend

The AIO (Asynchronous I/O) bdev backend provides access to files and block devices through the Linux kernel's AIO interface. It's ideal for development, testing, and scenarios where kernel storage stacks are acceptable.

## Architecture Overview

The AIO backend bridges SPDK's userspace architecture with kernel-based storage through Linux AIO:

```
SPDK Application
       ↓
AIO Bdev Module
       ↓
Linux AIO (libaio)
       ↓
Kernel VFS/Block Layer
       ↓
File System / Block Device
```

**Key Characteristics:**
- **Kernel Integration**: Uses kernel's async I/O interface
- **File Support**: Can operate on regular files or raw block devices
- **Simpler Setup**: No special driver requirements (unlike NVMe)
- **Lower Performance**: Kernel overhead vs pure userspace drivers

## Code References

### Core Implementation
- **Main Module**: `module/bdev/aio/bdev_aio.c`
- **Header**: `module/bdev/aio/bdev_aio.h`
- **RPC Interface**: `module/bdev/aio/bdev_aio_rpc.c`
- **Build Config**: `module/bdev/aio/Makefile`

### Function Table Implementation
**Location**: `module/bdev/aio/bdev_aio.c:814-822`
```c
static const struct spdk_bdev_fn_table aio_fn_table = {
    .destruct         = bdev_aio_destruct,
    .submit_request   = bdev_aio_submit_request,
    .io_type_supported = bdev_aio_io_type_supported,
    .get_io_channel   = bdev_aio_get_io_channel,
    .dump_info_json   = bdev_aio_dump_info_json,
    .write_config_json = bdev_aio_write_config_json,
};
```

### Key Function Implementations

#### **I/O Type Support** (`module/bdev/aio/bdev_aio.c:806-812`)
```c
static bool
bdev_aio_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
{
    switch (io_type) {
    case SPDK_BDEV_IO_TYPE_READ:
    case SPDK_BDEV_IO_TYPE_WRITE:
    case SPDK_BDEV_IO_TYPE_FLUSH:
    case SPDK_BDEV_IO_TYPE_SEEK_HOLE:
    case SPDK_BDEV_IO_TYPE_SEEK_DATA:
        return true;
    default:
        return false;
    }
}
```

#### **I/O Submission Logic** (`module/bdev/aio/bdev_aio.c:400-450`)
AIO uses Linux's `io_submit()` system call with `struct iocb` for async operations.

## Supported Features

### ✅ **Fully Supported**
- **Basic I/O**: READ, WRITE, FLUSH
- **File Operations**: SEEK_HOLE, SEEK_DATA (sparse file support)
- **Hot-plug**: Dynamic file/device attachment and removal
- **Configuration**: JSON-RPC management
- **Multiple Files**: Can create multiple AIO bdevs

### ❌ **Not Supported**
- **Metadata/DIF**: No protection information support
- **Zoned Storage**: No ZNS support
- **Memory Domains**: No special memory requirements
- **Acceleration Sequences**: No hardware acceleration
- **Advanced NVMe Operations**: UNMAP, WRITE_ZEROES, COMPARE operations

### ⚠️ **Limited Support**
- **Performance**: Kernel overhead limits IOPS and increases latency
- **TRIM/UNMAP**: Not supported through AIO interface
- **Atomic Operations**: No COMPARE_AND_WRITE support

## Configuration Examples

### **File-based AIO Bdev**
```bash
# Create AIO bdev from regular file
./scripts/rpc.py bdev_aio_create /path/to/file aio_file0 4096

# Parameters:
# - /path/to/file: Path to file (created if doesn't exist)
# - aio_file0: Bdev name  
# - 4096: Block size (optional, default 512)
```

### **Block Device AIO Bdev**
```bash
# Create AIO bdev from block device
./scripts/rpc.py bdev_aio_create /dev/sdb aio_sdb 512

# Use existing block device directly
# Block size should match device sector size
```

### **Configuration with Options**
```bash
# Create with specific configuration
./scripts/rpc.py bdev_aio_create \
    /path/to/storage.img \
    aio_storage \
    4096

# Verify creation
./scripts/rpc.py bdev_get_bdevs -b aio_storage
```

### **Large File Creation**
```bash
# Pre-create large sparse file
fallocate -l 10G /path/to/storage.img

# Or create with dd
dd if=/dev/zero of=/path/to/storage.img bs=1M count=10240

# Then create AIO bdev
./scripts/rpc.py bdev_aio_create /path/to/storage.img aio_10g 4096
```

## Performance Characteristics

### **Latency** (Typical)
- **Read**: 50-200μs (vs ~10μs for NVMe)
- **Write**: 100-500μs (depends on storage and kernel)
- **Syscall Overhead**: ~10-50μs additional vs userspace drivers

### **IOPS Scaling**
- **Single Queue**: 10K-50K IOPS (CPU and storage dependent)
- **Multiple Files**: Linear scaling up to storage limits
- **Queue Depth**: Benefits from higher QD (typically 32-128 optimal)

### **Throughput**
- **Limited by Storage**: Underlying device performance
- **Kernel Overhead**: ~10-30% performance penalty vs direct access
- **CPU Efficiency**: Higher CPU usage per IOPS than userspace drivers

## Use Cases & Applications

### **✅ Ideal For:**
- **Development & Testing**: Easy setup without special drivers
- **File-based Storage**: When working with existing filesystems
- **Prototype Development**: Quick storage backend for testing
- **Legacy Integration**: Systems requiring kernel storage stacks
- **Small Scale Applications**: Where peak performance isn't critical

### **❌ Not Recommended For:**
- **High-Performance Applications**: Use NVMe bdev instead
- **Production Storage Targets**: Kernel overhead impacts performance
- **Large Scale Deployments**: Better alternatives available
- **Latency-Critical Applications**: Too much kernel overhead

### **⚠️ Consider Carefully:**
- **Cloud Environments**: May be acceptable for development instances
- **Backup/Archive Storage**: Performance may be adequate
- **Mixed Workloads**: Could complement high-performance backends

## Configuration Best Practices

### **File Setup**
```bash
# Pre-allocate files to avoid runtime allocation overhead
fallocate -l 1G /path/to/storage.img

# For better performance, use block devices when possible
./scripts/rpc.py bdev_aio_create /dev/nvme1n1 aio_nvme 4096
```

### **Performance Tuning**
```bash
# Increase kernel AIO limits if needed
echo 1048576 > /proc/sys/fs/aio-max-nr

# Check current AIO usage
cat /proc/sys/fs/aio-nr
```

### **File System Considerations**
- **ext4**: Good general performance, supports fallocate
- **xfs**: Better for large files and concurrent access
- **Direct I/O**: AIO uses O_DIRECT to bypass page cache

## Limitations & Troubleshooting

### **Kernel Limitations**
- **AIO Limits**: System-wide limits on concurrent AIO operations
- **File System**: Some filesystems don't support all AIO features
- **Block Size**: Must match underlying device constraints

### **Common Issues**
```bash
# Check AIO limits
cat /proc/sys/fs/aio-max-nr    # Maximum allowed AIO requests
cat /proc/sys/fs/aio-nr        # Current AIO requests

# Permission issues
ls -l /path/to/device          # Check file/device permissions
sudo chmod 666 /dev/sdb        # Fix permissions if needed

# File doesn't exist
mkdir -p /path/to/storage/
touch /path/to/storage/file.img
```

### **Performance Debugging**
```bash
# Monitor AIO bdev performance
./scripts/rpc.py bdev_get_iostat -b aio_file0

# System-level monitoring
iostat -x 1      # Monitor underlying device
iotop            # Monitor I/O by process
```

## Integration Examples

### **With Logical Volumes**
```bash
# Create AIO bdev, then LVS on top
./scripts/rpc.py bdev_aio_create /path/to/storage.img aio_base 4096
./scripts/rpc.py bdev_lvol_create_lvstore aio_base lvs0
./scripts/rpc.py bdev_lvol_create -l lvs0 -n vol1 -s 1073741824
```

### **With Virtual Bdevs**
```bash
# Stack error injection on AIO for testing
./scripts/rpc.py bdev_aio_create /path/to/test.img aio_test 4096
./scripts/rpc.py bdev_error_create aio_test error_test
```

### **Multiple AIO Bdevs**
```bash
# Create multiple AIO bdevs for RAID
./scripts/rpc.py bdev_aio_create /path/to/disk1.img aio_disk1 4096
./scripts/rpc.py bdev_aio_create /path/to/disk2.img aio_disk2 4096
./scripts/rpc.py bdev_raid_create -n raid0_aio -z 64 -r 0 -b "aio_disk1 aio_disk2"
```

## Development & Testing

### **Quick Setup for Development**
```bash
# Create test storage file
dd if=/dev/zero of=/tmp/test_storage.img bs=1M count=1024

# Create AIO bdev
./scripts/rpc.py bdev_aio_create /tmp/test_storage.img test_aio 4096

# Test basic functionality
./test/bdev/bdev.sh -b test_aio
```

### **FIO Testing**
```bash
# Test performance with FIO
fio --name=aio_test \
    --ioengine=spdk_bdev \
    --spdk_conf=./spdk.conf \
    --thread=1 \
    --group_reporting \
    --direct=1 \
    --verify=0 \
    --randrepeat=0 \
    --ioscheduler=noop \
    --iodepth=32 \
    --bs=4k \
    --rw=randrw \
    --rwmixread=70 \
    --time_based \
    --runtime=60 \
    --filename=test_aio
```

## Security Considerations

### **File Permissions**
- **File Access**: AIO bdevs inherit file system permissions
- **Device Access**: Block devices typically require root privileges
- **Path Validation**: Ensure paths are validated to prevent directory traversal

### **Data Protection**
- **No Encryption**: AIO backend doesn't provide encryption
- **File System Level**: Rely on underlying filesystem encryption if needed
- **Access Control**: Use filesystem ACLs for fine-grained access control

## Code Examples

### **Custom AIO Integration**
```c
// Example: Creating AIO bdev programmatically
#include "spdk/bdev.h"

// See module/bdev/aio/bdev_aio.c for complete implementation
// Key functions:
// - bdev_aio_create(): Create AIO bdev from file/device path
// - bdev_aio_submit_request(): Handle I/O requests via Linux AIO
```

---

The AIO bdev backend serves as SPDK's bridge to traditional kernel-based storage, providing an accessible entry point for development and testing while maintaining compatibility with existing file and block device infrastructure.